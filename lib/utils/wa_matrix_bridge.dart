// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import 'matrix_sdk_extensions/matrix_file_extension.dart';

import '../config/setting_keys.dart';
import 'wa_call_link.dart';
import 'platform_infos.dart';

/// Converts WA bridge events into virtual Matrix rooms injected via handleSync.
/// Once injected, FluffyChat treats WA rooms identically to real Matrix rooms.
class WaMatrixBridge {
  WaMatrixBridge._();
  static final instance = WaMatrixBridge._();

  Client? _client;

  // Bidirectional mapping. Keyed by a composite "<accountId>|<waJid>" so the
  // same WhatsApp chat on different accounts maps to distinct Matrix rooms.
  // For the "default" account the composite key collapses to just the JID, so
  // existing single-account installs keep working unchanged.
  final _waToMatrix = <String, String>{}; // compositeKey -> matrixRoomId
  final _matrixToWa = <String, String>{}; // matrixRoomId -> waJid
  final _matrixToAccount = <String, String>{}; // matrixRoomId -> accountId

  static const _defaultAccount = 'default';

  // Composite map key. Default account uses the bare JID for back-compat.
  static const _sep = '\u0001';
  static String _key(String accountId, String waJid) =>
      accountId == _defaultAccount ? waJid : '$accountId$_sep$waJid';

  // eventId → original event data, kept until media_ready allows re-injection
  final _pendingMediaEvents = <String, Map<String, dynamic>>{};

  // "$matrixRoomId/$senderId" → last display name we injected, avoids re-injecting unchanged names
  final _senderNames = <String, String>{};

  StreamSubscription<BridgeEvent>? _sub;

  // Serializes all handleSync injections. The SDK's handleSync is NOT internally
  // serialized, so concurrent unawaited calls interleave at every await and the
  // last DB writer wins — which let a URL-less media placeholder clobber the
  // media_ready re-injection that carries the attachment URL. Chaining every
  // injection through this future guarantees submission-order application, so a
  // placeholder always lands before its media_ready URL update.
  Future<void> _injectChain = Future.value();
  // Serializes backfill chunks (a large window arrives as several chunked
  // events) so they inject in order.
  Future<void> _backfillChain = Future.value();

  // Per-account space room ids and connected phone numbers.
  final _spaceIds = <String, String>{}; // accountId -> space room id
  final _connectedPhones = <String, String>{}; // accountId -> phone

  // Cached in memory for the hot path (new-room lazy backfill); loaded in init.
  int _defaultBackfillDays = 30;

  static const _bridgeStateType = 'org.tjena.bridge.local';

  // Account id of an existing bridged room (for outgoing calls). Defaults to
  // "default" for legacy rooms with no recorded account.
  String _accOf(String matrixRoomId) =>
      _matrixToAccount[matrixRoomId] ?? _defaultAccount;

  static String _spaceRoomIdFor(String accountId) => accountId == _defaultAccount
      ? '!wa_space_local:local'
      : '!wa_space_${accountId}_local:local';

  static String _toMatrixId(String accountId, String waRoomId) {
    final safe = waRoomId.replaceAll('@', '_');
    return accountId == _defaultAccount
        ? '!wa_$safe:local'
        : '!wa_${accountId}_$safe:local';
  }

  // ── Init ─────────────────────────────────────────────────────────────────────

  // Reconstruct the WA JID from a virtual Matrix room ID produced by _toMatrixId.
  // Returns null if the room ID doesn't look like a WA virtual room.
  static String? _waIdFromRoomId(String roomId) {
    if (!roomId.startsWith('!wa_') || !roomId.endsWith(':local')) return null;
    final inner = roomId.substring(4, roomId.length - 6);
    for (final server in ['s.whatsapp.net', 'g.us', 'broadcast', 'lid']) {
      if (inner.endsWith('_$server')) {
        final user = inner.substring(0, inner.length - server.length - 1);
        return '$user@$server';
      }
    }
    return null;
  }

  static const _roomMappingsKey = 'wa_bridge_room_mappings';
  static const _phonesKey = 'wa_bridge_account_phones';
  static const _customNamesKey = 'wa_bridge_custom_names';

  // User-set custom room names (matrixRoomId -> name). Override automatic names.
  final _customNames = <String, String>{};

  // Our own reaction events ('matrixRoomId|targetEventId' -> reaction eventId),
  // so we can change/remove them (WhatsApp doesn't echo our own reactions back).
  final _ownReactionIds = <String, String>{};

  // Persist the current WA↔Matrix room mapping to SharedPreferences so it
  // survives process restarts without relying on Matrix SDK state-event loading.
  Future<void> _saveRoomMappings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_roomMappingsKey, jsonEncode(Map.of(_waToMatrix)));
    } catch (e) {
      Logs().w('[WaBridge] save room mappings failed: $e');
    }
  }

  // Persist each account's connected phone number (for stable space names).
  Future<void> _savePhones() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_phonesKey, jsonEncode(Map.of(_connectedPhones)));
    } catch (e) {
      Logs().w('[WaBridge] save phones failed: $e');
    }
  }

  Future<void> init(Client client) async {
    _client = client;

    // ① Load from SharedPreferences — fast, reliable, survives process kills.
    // Keys are composite "<accountId><jid>" (default account = bare jid).
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString(_roomMappingsKey);
      if (str != null) {
        final raw = jsonDecode(str) as Map<String, dynamic>;
        for (final e in raw.entries) {
          final matrixId = e.value as String;
          _waToMatrix[e.key] = matrixId;
          final sep = e.key.indexOf(_sep);
          final accountId = sep < 0 ? _defaultAccount : e.key.substring(0, sep);
          final jid = sep < 0 ? e.key : e.key.substring(sep + 1);
          _matrixToWa[matrixId] = jid;
          _matrixToAccount[matrixId] = accountId;
        }
      }
    } catch (e) {
      Logs().w('[WaBridge] load room mappings failed: $e');
    }

    // ② Supplement from client.rooms (covers first-ever install + space rooms).
    for (final room in client.rooms) {
      if (room.id.startsWith('!wa_space')) continue; // space rooms aren't chats
      final st = room.getState(_bridgeStateType)?.content;
      var waId = st?['wa_room_id'] as String?;
      final accountId = (st?['account_id'] as String?) ?? _defaultAccount;
      waId ??= _waIdFromRoomId(room.id);
      if (waId != null && !_matrixToWa.containsKey(room.id)) {
        _waToMatrix[_key(accountId, waId)] = room.id;
        _matrixToWa[room.id] = waId;
        _matrixToAccount[room.id] = accountId;
      }
    }

    // ③ Persist the complete mapping back so next restart is instantaneous.
    // ignore: unawaited_futures
    _saveRoomMappings();

    // ③b Restore each account's phone number so its space is named with the
    // number immediately (otherwise spaces show a generic "WhatsApp" until the
    // account reconnects).
    try {
      final prefs = await SharedPreferences.getInstance();
      final ps = prefs.getString(_phonesKey);
      if (ps != null) {
        (jsonDecode(ps) as Map<String, dynamic>)
            .forEach((k, v) => _connectedPhones[k] = v as String);
      }
    } catch (e) {
      Logs().w('[WaBridge] load phones failed: $e');
    }

    // ③c Restore user-set custom room names and re-apply them so they survive
    // restarts and win over automatic name refreshes.
    try {
      final prefs = await SharedPreferences.getInstance();
      final cn = prefs.getString(_customNamesKey);
      if (cn != null) {
        (jsonDecode(cn) as Map<String, dynamic>)
            .forEach((k, v) => _customNames[k] = v as String);
      }
    } catch (e) {
      Logs().w('[WaBridge] load custom names failed: $e');
    }
    _customNames.forEach(_injectName);

    // ④ Ensure each account's WhatsApp space exists and (re-)parents all of its
    // chats. This repairs chats that were created without a space (e.g. via the
    // picker before the account had connected). _initSpace adds every known
    // account room as a space child.
    for (final accountId in _matrixToAccount.values.toSet()) {
      _ensureSpace(accountId);
    }

    _sub?.cancel();
    _sub = TjenaBridge.instance.events.listen(
      _onBridgeEvent,
      onError: (e, s) => Logs().w('[WaBridge] stream error', e, s),
      cancelOnError: false,
    );

    // Repair nameless rooms now, and again shortly after (rooms can finish
    // loading / syncing a moment later). Logged at warning level so it is
    // visible in release logcat regardless of capture timing.
    _repairRoomNames('init');
    Future.delayed(const Duration(seconds: 3), () => _repairRoomNames('delayed'));

    // Load the default backfill window for lazy room creation.
    _defaultBackfillDays = await getDefaultBackfillDays();
  }

  // Give every WA room a non-empty, non-JID name. An empty name makes the SDK
  // show "leerer chat" and probe the fake homeserver for the DM partner. We seed
  // the bare number; a real push/contact name upgrades it later. Idempotent.
  void _repairRoomNames(String reason) {
    final client = _client;
    if (client == null) return;
    var repaired = 0;
    for (final room in client.rooms) {
      if (room.id.startsWith('!wa_space')) continue;
      final st = room.getState(_bridgeStateType)?.content;
      var waId = st?['wa_room_id'] as String?;
      final accountId = (st?['account_id'] as String?) ??
          _matrixToAccount[room.id] ??
          _defaultAccount;
      waId ??= _waIdFromRoomId(room.id);
      if (waId == null) continue;
      if (!_matrixToWa.containsKey(room.id)) {
        _waToMatrix[_key(accountId, waId)] = room.id;
        _matrixToWa[room.id] = waId;
        _matrixToAccount[room.id] = accountId;
      }
      final n = room.name;
      if (n.isEmpty || n.contains('@') || n == room.id) {
        _pushNameUpdate(accountId, waId, waId.split('@').first);
        repaired++;
      }
    }
    Logs().w('[WaBridge] name repair ($reason): scanned ${client.rooms.length} rooms, repaired $repaired');
  }

  bool isWaRoom(String matrixRoomId) => _matrixToWa.containsKey(matrixRoomId);

  /// True if [matrixRoomId] is a 1:1 WhatsApp chat (not a group/broadcast).
  /// Used to show the call button (WhatsApp call links) in DM chats, whose
  /// virtual rooms aren't flagged isDirectChat by the SDK.
  bool isWaDirectChat(String matrixRoomId) {
    final waId = _matrixToWa[matrixRoomId];
    return waId != null &&
        !waId.endsWith('@g.us') &&
        !waId.endsWith('@broadcast');
  }
  String? waRoomId(String matrixRoomId) => _matrixToWa[matrixRoomId];
  String? matrixRoomId(String waRoomId) => _waToMatrix[waRoomId];

  /// The existing Matrix room id for a WhatsApp chat JID, or null if no room has
  /// been created for it yet. Lets the picker show the cached room avatar without
  /// any network fetch.
  String? existingMatrixRoom(String jid, {String accountId = _defaultAccount}) =>
      _waToMatrix[_key(accountId, jid)];

  /// Returns the Matrix room ID for [rawPhone], creating a virtual WA room
  /// if one doesn't exist yet. Returns null only if the bridge is not linked.
  String? ensureChatForPhone(String rawPhone,
      {String accountId = _defaultAccount}) {
    final phone = rawPhone.replaceAll(RegExp(r'[\s+\-()]'), '');
    final jid = '$phone@s.whatsapp.net';
    if (!_waToMatrix.containsKey(_key(accountId, jid))) {
      _ensureRoom(accountId, jid, '+$phone', isDM: true);
    }
    return _waToMatrix[_key(accountId, jid)];
  }
  // True if any account is connected, OR rooms from a previous session exist.
  bool get isLinked => _connectedPhones.isNotEmpty || _waToMatrix.isNotEmpty;
  String? get connectedPhone => _connectedPhones[_defaultAccount];
  String? matrixRoomIdForPhone(String phone) {
    final jid = '${phone.replaceAll('+', '').replaceAll(' ', '')}@s.whatsapp.net';
    return _waToMatrix[_key(_defaultAccount, jid)];
  }

  // ── Public actions ────────────────────────────────────────────────────────────

  Future<void> sendText(String matrixRoomId, String text) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final eventId = '\$wa_out_${DateTime.now().millisecondsSinceEpoch}';
    // Inject locally first so the message appears immediately in the chat.
    final client = _client;
    if (client?.userID != null) {
      client!.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixRoomId: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: [
                MatrixEvent(
                  type: EventTypes.Message,
                  content: {'msgtype': 'm.text', 'body': text},
                  senderId: client.userID!,
                  eventId: eventId,
                  originServerTs: DateTime.now(),
                  roomId: matrixRoomId,
                ),
              ],
              limited: false,
            ),
          ),
        }),
      ));
    }
    await TjenaBridge.instance.sendText(waId, eventId, text, accountID: _accOf(matrixRoomId));
  }

  /// Send a media file through WhatsApp. Injects a local Matrix event immediately
  /// for instant display, then uploads and delivers via the Go bridge.
  Future<void> sendFile(
    String matrixRoomId,
    Uint8List bytes,
    String mimeType,
    String fileName,
  ) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final client = _client;
    if (client?.userID == null) return;

    final eventId = '\$wa_out_media_${DateTime.now().millisecondsSinceEpoch}';
    final msgtype = mimeType.startsWith('image/')
        ? 'm.image'
        : mimeType.startsWith('video/')
            ? 'm.video'
            : mimeType.startsWith('audio/')
                ? 'm.audio'
                : 'm.file';
    final c = client!;

    // Store bytes locally so the outgoing bubble can render them.
    final mxcUri = Uri.parse('mxc://wa-media/${eventId.replaceAll(r'$', '')}');
    await c.database.storeFile(
      mxcUri,
      bytes,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    // Inject immediately for optimistic display.
    c.handleSync(SyncUpdate(
      nextBatch: c.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixRoomId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: EventTypes.Message,
                content: {
                  'msgtype': msgtype,
                  'body': fileName,
                  'url': mxcUri.toString(),
                  'info': {'mimetype': mimeType, 'size': bytes.length},
                },
                senderId: c.userID!,
                eventId: eventId,
                originServerTs: DateTime.now(),
                roomId: matrixRoomId,
              ),
            ],
            limited: false,
          ),
        ),
      }),
    ));

    try {
      await TjenaBridge.instance.sendMedia(waId, eventId, mimeType, bytes, accountID: _accOf(matrixRoomId));
    } catch (e) {
      Logs().w('[WaBridge] sendFile failed: $e');
    }
  }

  /// Send a location through WhatsApp. Injects a local Matrix event immediately.
  Future<void> sendLocation(
    String matrixRoomId,
    double lat,
    double lon,
  ) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final client = _client;
    if (client?.userID == null) return;

    final eventId = '\$wa_out_loc_${DateTime.now().millisecondsSinceEpoch}';
    final geoUri = 'geo:$lat,$lon';
    final c = client!;

    c.handleSync(SyncUpdate(
      nextBatch: c.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixRoomId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: EventTypes.Message,
                content: {
                  'msgtype': 'm.location',
                  'body': geoUri,
                  'geo_uri': geoUri,
                },
                senderId: c.userID!,
                eventId: eventId,
                originServerTs: DateTime.now(),
                roomId: matrixRoomId,
              ),
            ],
            limited: false,
          ),
        ),
      }),
    ));

    try {
      await TjenaBridge.instance.sendLocation(waId, lat, lon, accountID: _accOf(matrixRoomId));
    } catch (e) {
      Logs().w('[WaBridge] sendLocation failed: $e');
    }
  }

  /// Refresh name and avatar for a room from the Go bridge (live network fetch).
  /// Also immediately repairs a blank/JID title with the bare number so the chat
  /// never stays "leerer chat" — the real name overwrites it when the Go bridge
  /// responds (if the contact is resolvable).
  Future<void> refreshRoom(String matrixRoomId) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final accountId = _accOf(matrixRoomId);
    final n = _client?.getRoomById(matrixRoomId)?.name ?? '';
    if (n.isEmpty || n.contains('@') || n == matrixRoomId) {
      _pushNameUpdate(accountId, waId, waId.split('@').first);
    }
    try {
      await TjenaBridge.instance.refreshRoom(waId, accountID: accountId);
    } catch (e) {
      Logs().w('[WaBridge] refreshRoom failed: $e');
    }
    // Refresh the group member list on manual sync.
    if (waId.endsWith('@g.us')) {
      // ignore: unawaited_futures
      syncGroupMembers(matrixRoomId);
    }
  }

  /// Full repair + re-sync of a WhatsApp chat (the per-chat "WA sync" action) —
  /// fixes things that otherwise need a re-link:
  ///  0) repair the account's space (correct phone-number name) and re-parent
  ///     this chat into it,
  ///  1) refresh the chat name + profile picture (+ group member/contact names),
  ///  2) wipe this chat's local timeline so the re-pull is clean (no duplicate
  ///     or mis-ordered messages),
  ///  3) cleanly re-pull [days] days of history from the cache.
  ///
  /// Returns the number of cached messages re-pulled (0 = nothing in the cache
  /// for this chat/window).
  Future<int> resyncRoom(String matrixRoomId, int days) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null || _client == null) return 0;
    final accountId = _accOf(matrixRoomId);

    // 0) Repair the account's space: refresh its phone number, (re)name the
    //    space correctly, and make sure this chat is parented to it.
    try {
      final st = await TjenaBridge.instance.getState(accountID: accountId);
      final phone = st.phone;
      if (phone.isNotEmpty && _connectedPhones[accountId] != phone) {
        _connectedPhones[accountId] = phone;
        // ignore: unawaited_futures
        _savePhones();
      }
    } catch (e) {
      Logs().w('[WaBridge] repair getState failed: $e');
    }
    _initSpace(accountId, _connectedPhones[accountId] ?? ''); // create or rename
    _addRoomToSpace(accountId, matrixRoomId); // ensure parented

    // 1) name + photo (+ group members for in-chat contact names)
    await refreshRoom(matrixRoomId);

    // 2+3) clean re-pull of N days from the cache. backfillFromCache → the
    //      backfill handler wipes the room timeline first, then re-injects the
    //      window chronologically, so there are no duplicates or mis-ordering.
    if (days <= 0) return 0;
    return TjenaBridge.instance
        .backfillFromCache(waId, days, accountID: accountId);
  }

  /// Pull WhatsApp message history for a chat going back [days] days from the
  /// local cache (populated by the link-time history sync). Reliable — no
  /// network anchor needed. Messages arrive as backfill events.
  /// Returns the number of cached messages found for the window (0 = the local
  /// cache has no history for this chat/window).
  Future<int> requestBackfill(String matrixRoomId, int days) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) throw Exception('not a WhatsApp chat');
    final accountId = _accOf(matrixRoomId);
    return TjenaBridge.instance
        .backfillFromCache(waId, days, accountID: accountId);
  }

  /// Fetch a WhatsApp group's participants and inject them as room members, so
  /// FluffyChat shows the member list and @-mention autocomplete works. The
  /// member ghost ids match message senders (@wa_<user>:tjena.local).
  Future<void> syncGroupMembers(String matrixRoomId) async {
    final waId = _matrixToWa[matrixRoomId];
    final client = _client;
    if (waId == null || client?.userID == null || !waId.endsWith('@g.us')) {
      return;
    }
    try {
      final members = await TjenaBridge.instance
          .getGroupMembers(waId, accountID: _accOf(matrixRoomId));
      if (members.isEmpty) return;
      final now = DateTime.now();
      final stateEvents = <MatrixEvent>[];
      for (final m in members) {
        final user = m['user'] as String? ?? '';
        if (user.isEmpty) continue;
        final ghost = '@wa_$user:tjena.local';
        final name = m['name'] as String? ?? '';
        final content = <String, dynamic>{'membership': 'join'};
        if (name.isNotEmpty) content['displayname'] = name;
        stateEvents.add(MatrixEvent(
          type: EventTypes.RoomMember,
          content: content,
          senderId: ghost,
          eventId: '\$wamember_${_safe(ghost)}_${_safe(matrixRoomId)}',
          originServerTs: now,
          stateKey: ghost,
        ));
      }
      if (stateEvents.isEmpty) return;
      // ignore: unawaited_futures
      _inject(SyncUpdate(
        nextBatch: client!.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixRoomId: JoinedRoomUpdate(state: stateEvents),
        }),
      ));
    } catch (e) {
      Logs().w('[WaBridge] syncGroupMembers failed: $e');
    }
  }

  // ── Chat picker + cached-history sync ───────────────────────────────────────

  static const _linkModeKey = 'wa_link_mode'; // 'all' | 'silent' | '' (unset)
  static const _defaultBackfillDaysKey = 'wa_default_backfill_days';

  /// Link mode chosen after pairing: 'all' (create every chat) or 'silent'
  /// (cache only; create a room when a new message arrives). '' = not chosen.
  Future<String> getLinkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_linkModeKey) ?? '';
  }

  Future<void> setLinkMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_linkModeKey, mode);
  }

  /// Default number of days to backfill when a chat is created lazily (silent
  /// mode) or as the picker's default. 0 = no backfill.
  Future<int> getDefaultBackfillDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_defaultBackfillDaysKey) ?? 30;
  }

  Future<void> setDefaultBackfillDays(int days) async {
    _defaultBackfillDays = days;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_defaultBackfillDaysKey, days);
  }

  /// List chats for the picker: the cached chats (with real last-activity for
  /// every chat) merged with any saved contacts/groups not yet in the cache.
  /// Each entry: jid, name, is_group, phone, synced, last_activity (ms).
  Future<List<Map<String, dynamic>>> listChatsWithStatus(
      {String accountId = _defaultAccount}) async {
    final byJid = <String, Map<String, dynamic>>{};

    // Contact-store names first (saved contacts + group names) — these are the
    // best source of real display names. Keyed by jid for name lookups below.
    final contacts = <String, Map<String, dynamic>>{};
    for (final c in await TjenaBridge.instance.listChats(accountID: accountId)) {
      final jid = c['jid'] as String? ?? '';
      if (jid.isEmpty) continue;
      contacts[jid] = c;
    }

    // Cached chats first — these carry last_ts (recency) for every chat. The
    // cached name can be a bare phone number (when the message arrived before
    // the contact resolved); upgrade it with a real contact-store name so the
    // picker shows names, not numbers.
    for (final c in await TjenaBridge.instance.listCachedChats(accountID: accountId)) {
      final jid = c['jid'] as String? ?? '';
      if (jid.isEmpty) continue;
      final isGroup = c['is_group'] as bool? ?? false;
      var name = (c['name'] as String?) ?? '';
      if (isGroup) {
        // A group's name is its subject; the cached name can be a stale sender
        // name, so prefer the authoritative group name from the group list.
        final groupName = (contacts[jid]?['name'] as String?) ?? '';
        if (groupName.isNotEmpty) name = groupName;
      } else if (!_looksLikeName(name)) {
        final contactName = (contacts[jid]?['name'] as String?) ?? '';
        if (_looksLikeName(contactName)) name = contactName;
      }
      byJid[jid] = {
        'jid': jid,
        'name': name,
        'is_group': isGroup,
        'phone': c['phone'] ?? '',
        'last_activity': ((c['last_ts'] as num?)?.toInt() ?? 0) * 1000,
      };
    }
    // Merge in contacts/groups without cached history.
    for (final entry in contacts.entries) {
      final jid = entry.key;
      if (byJid.containsKey(jid)) continue;
      final c = entry.value;
      byJid[jid] = {
        'jid': jid,
        'name': c['name'] ?? '',
        'is_group': c['is_group'] ?? false,
        'phone': c['phone'] ?? '',
        'last_activity': 0,
      };
    }

    final out = byJid.values.toList();
    for (final c in out) {
      c['synced'] = _waToMatrix.containsKey(_key(accountId, c['jid'] as String));
    }
    return out;
  }

  /// Fetch a chat's WhatsApp profile-picture URL (direct CDN https link).
  Future<String> chatAvatarUrl(String jid, {String accountId = _defaultAccount}) =>
      TjenaBridge.instance.getChatAvatarUrl(jid, accountID: accountId);

  /// Create a room for [jid] and backfill [days] days from the local cache.
  Future<void> syncChat(String jid, String name, bool isGroup, int days,
      {String accountId = _defaultAccount}) async {
    final displayName = name.isNotEmpty ? name : jid.split('@').first;
    _ensureRoom(accountId, jid, displayName, isDM: !isGroup);
    if (days > 0) {
      // ignore: unawaited_futures
      TjenaBridge.instance.backfillFromCache(jid, days, accountID: accountId);
    }
    final mid = _waToMatrix[_key(accountId, jid)];
    if (mid != null) {
      // ignore: unawaited_futures
      refreshRoom(mid); // real name + photo
    }
  }

  /// Ensure a room exists for [jid] (creating + backfilling with the default
  /// window if new) and return its Matrix room id, for "open this chat" flows.
  Future<String?> openChatRoom(String jid, String name, bool isGroup,
      {String accountId = _defaultAccount}) async {
    await syncChat(jid, name, isGroup, _defaultBackfillDays, accountId: accountId);
    return _waToMatrix[_key(accountId, jid)];
  }

  /// Create rooms + backfill [days] for every cached chat (link-mode "all").
  Future<int> syncAllCachedChats(int days,
      {String accountId = _defaultAccount}) async {
    final chats = await TjenaBridge.instance.listCachedChats(accountID: accountId);
    for (final c in chats) {
      final jid = c['jid'] as String? ?? '';
      if (jid.isEmpty || _waToMatrix.containsKey(_key(accountId, jid))) continue;
      await syncChat(
        jid,
        c['name'] as String? ?? '',
        c['is_group'] as bool? ?? false,
        days,
        accountId: accountId,
      );
    }
    return chats.length;
  }

  /// Remove a chat's room from the bridge (keeps WhatsApp linked).
  Future<void> unsyncChat(String jid, {String accountId = _defaultAccount}) async {
    final mid = _waToMatrix[_key(accountId, jid)];
    if (mid == null) return;
    final client = _client;
    if (client != null) {
      try { await client.database.forgetRoom(mid); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == mid);
      client.archivedRooms.removeWhere((r) => r.room.id == mid);
    }
    _waToMatrix.remove(_key(accountId, jid));
    _matrixToWa.remove(mid);
    _matrixToAccount.remove(mid);
    await _saveRoomMappings();
  }

  /// Call when the user opens a WA room to clear unread count and send WA receipt.
  Future<void> markRoomRead(Client client, String matrixRoomId) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final room = client.getRoomById(matrixRoomId);
    final lastEventId = room?.lastEvent?.eventId;
    // Reset unread count locally via a read receipt ephemeral event.
    if (lastEventId != null) {
      // ignore: unawaited_futures
      client.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixRoomId: JoinedRoomUpdate(
            ephemeral: [
              BasicEvent(
                type: 'm.receipt',
                content: {
                  lastEventId: {
                    'm.read': {
                      client.userID!: {
                        'ts': DateTime.now().millisecondsSinceEpoch,
                      },
                    },
                  },
                },
              ),
            ],
            unreadNotifications: UnreadNotificationCounts(
              notificationCount: 0,
              highlightCount: 0,
            ),
          ),
        }),
      ));
    }
    // Send WA read receipt (fire and forget — failures are non-fatal).
    try {
      await TjenaBridge.instance.markRead(waId, lastEventId ?? '', accountID: _accOf(matrixRoomId));
    } catch (_) {}
  }

  /// Send a reaction to a WA message.
  /// Pass [emoji] as empty string to remove an existing reaction.
  Future<void> sendReaction(
    String matrixRoomId,
    String targetMatrixEventId,
    String emoji,
  ) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final targetWaId = targetMatrixEventId.startsWith(r'$wa_')
        ? targetMatrixEventId.substring(4)
        : targetMatrixEventId;

    // Optimistically reflect our OWN reaction — WhatsApp doesn't echo own
    // reactions back to the companion, so otherwise it never appears here.
    final client = _client;
    if (client?.userID != null) {
      final key = '$matrixRoomId|$targetMatrixEventId';
      final ts = DateTime.now();
      final events = <MatrixEvent>[];
      // Remove any previous own reaction on this message (change/clear).
      final prev = _ownReactionIds.remove(key);
      if (prev != null) {
        events.add(MatrixEvent(
          type: EventTypes.Redaction,
          content: {'redacts': prev},
          senderId: client!.userID!,
          eventId: '\$wa_react_redact_${ts.millisecondsSinceEpoch}',
          originServerTs: ts,
          roomId: matrixRoomId,
        ));
      }
      if (emoji.isNotEmpty) {
        final rid = '\$wa_react_own_${ts.millisecondsSinceEpoch}';
        _ownReactionIds[key] = rid;
        events.add(MatrixEvent(
          type: 'm.reaction',
          content: {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': targetMatrixEventId,
              'key': emoji,
            },
          },
          senderId: client!.userID!,
          eventId: rid,
          originServerTs: ts,
          roomId: matrixRoomId,
        ));
      }
      if (events.isNotEmpty) {
        // ignore: unawaited_futures
        client!.handleSync(SyncUpdate(
          nextBatch: client.prevBatch ?? '',
          rooms: RoomsUpdate(join: {
            matrixRoomId: JoinedRoomUpdate(
              timeline: TimelineUpdate(events: events, limited: false),
            ),
          }),
        ));
      }
    }

    try {
      await TjenaBridge.instance.sendReaction(waId, targetWaId, emoji, accountID: _accOf(matrixRoomId));
    } catch (_) {}
  }

  /// Delete a WA message and inject a local Matrix redaction.
  Future<void> redactMessage(String matrixRoomId, String eventId) async {
    final waId = _matrixToWa[matrixRoomId];
    final client = _client;
    if (waId == null || client?.userID == null) return;
    final targetWaId =
        eventId.startsWith(r'$wa_') ? eventId.substring(4) : eventId;
    try {
      await TjenaBridge.instance.sendRedaction(waId, targetWaId, accountID: _accOf(matrixRoomId));
    } catch (_) {}
    // Inject local redaction for immediate UI update.
    final ts = DateTime.now();
    // ignore: unawaited_futures
    client!.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixRoomId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: EventTypes.Redaction,
                content: {'redacts': eventId},
                senderId: client.userID!,
                eventId:
                    '\$wa_redact_${_safe(eventId)}_${ts.millisecondsSinceEpoch}',
                originServerTs: ts,
                roomId: matrixRoomId,
              ),
            ],
            limited: false,
          ),
        ),
      }),
    ));
  }

  /// Fire a typing notification to WA (best-effort, never throws).
  void notifyTyping(String matrixRoomId, bool typing) {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    TjenaBridge.instance
        .setTyping(waId, typing: typing, accountID: _accOf(matrixRoomId))
        .catchError((_) {});
  }

  /// Remove a WA virtual room from all in-memory and DB state.
  Future<void> removeRoom(Client client, String matrixRoomId) async {
    final waId = _matrixToWa.remove(matrixRoomId);
    if (waId != null) _waToMatrix.remove(waId);
    await _saveRoomMappings();
    try { await client.database.forgetRoom(matrixRoomId); } catch (_) {}
    client.rooms.removeWhere((r) => r.id == matrixRoomId);
    client.archivedRooms.removeWhere((r) => r.room.id == matrixRoomId);
  }

  /// Remove ALL WA virtual rooms from in-memory and DB state, and clear the
  /// Go bridge's persisted room list so they aren't restored on next start.
  Future<void> clearAllRooms(Client client) async {
    final matrixIds = _matrixToWa.keys.toList();
    for (final mid in matrixIds) {
      try { await client.database.forgetRoom(mid); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == mid);
      client.archivedRooms.removeWhere((r) => r.room.id == mid);
    }
    // Also remove all per-account space rooms.
    for (final sid in _spaceIds.values) {
      try { await client.database.forgetRoom(sid); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == sid);
    }
    _spaceIds.clear();
    _matrixToAccount.clear();
    _waToMatrix.clear();
    _matrixToWa.clear();
    _pendingMediaEvents.clear();
    _senderNames.clear();
    await _saveRoomMappings();
    try {
      await TjenaBridge.instance.clearPersistedRooms();
    } catch (e) {
      Logs().w('[WaBridge] clearPersistedRooms failed: $e');
    }
  }

  /// Clean slate for one account: forget its rooms + clear its history cache.
  /// WhatsApp itself is untouched. Used by the link screen's "start fresh" box.
  /// Remove ONLY this account's WhatsApp rooms (and its space) from Tjena. Does
  /// not touch the history cache or the WhatsApp session — new messages recreate
  /// the rooms. Used by the per-account "delete all WA rooms" action so it only
  /// affects the account whose settings are open.
  Future<void> clearAccountRooms(Client client, String accountId) async {
    final mids = _matrixToAccount.entries
        .where((e) => e.value == accountId)
        .map((e) => e.key)
        .toList();
    for (final mid in mids) {
      final jid = _matrixToWa[mid];
      try {
        await client.database.forgetRoom(mid);
      } catch (_) {}
      client.rooms.removeWhere((r) => r.id == mid);
      client.archivedRooms.removeWhere((r) => r.room.id == mid);
      _matrixToWa.remove(mid);
      _matrixToAccount.remove(mid);
      if (jid != null) _waToMatrix.remove(_key(accountId, jid));
    }
    final sid = _spaceIds.remove(accountId);
    if (sid != null) {
      try {
        await client.database.forgetRoom(sid);
      } catch (_) {}
      client.rooms.removeWhere((r) => r.id == sid);
    }
    await _saveRoomMappings();
  }

  Future<void> clearAccountData(Client client, String accountId) async {
    // Forget this account's rooms.
    final mids = _matrixToAccount.entries
        .where((e) => e.value == accountId)
        .map((e) => e.key)
        .toList();
    for (final mid in mids) {
      final jid = _matrixToWa[mid];
      try { await client.database.forgetRoom(mid); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == mid);
      client.archivedRooms.removeWhere((r) => r.room.id == mid);
      _matrixToWa.remove(mid);
      _matrixToAccount.remove(mid);
      if (jid != null) _waToMatrix.remove(_key(accountId, jid));
    }
    // Remove this account's space room.
    final sid = _spaceIds.remove(accountId);
    if (sid != null) {
      try { await client.database.forgetRoom(sid); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == sid);
    }
    await _saveRoomMappings();
    // Wipe the Go-side history cache for this account.
    try {
      await TjenaBridge.instance.clearCache(accountID: accountId);
    } catch (e) {
      Logs().w('[WaBridge] clearCache failed: $e');
    }
    // Reset the whatsmeow session store too, so "Start fresh" recovers even from
    // a corrupted store ("database disk image is malformed") that would
    // otherwise block re-linking.
    try {
      await TjenaBridge.instance.forceReset(accountID: accountId);
    } catch (e) {
      Logs().w('[WaBridge] forceReset failed: $e');
    }
  }

  // ── Bridge event dispatch ─────────────────────────────────────────────────────

  void _onBridgeEvent(BridgeEvent evt) {
    try {
      _onBridgeEventInner(evt);
    } catch (e, s) {
      Logs().w('[WaBridge] unhandled event error (${evt.type})', e, s);
    }
  }

  void _onBridgeEventInner(BridgeEvent evt) {
    // Every WA event is tagged with the account it came from (default "default").
    final acc = evt.data['account_id'] as String? ?? _defaultAccount;
    switch (evt.type) {
      case BridgeEventType.state:
        final phone = evt.data['phone'] as String? ?? '';
        final connected = evt.data['connected'] as bool? ?? false;
        if (connected && phone.isNotEmpty && _connectedPhones[acc] != phone) {
          _connectedPhones[acc] = phone;
          // ignore: unawaited_futures
          _savePhones();
          _initSpace(acc, phone);
        }

      case BridgeEventType.roomCreated:
        final data = evt.data['room'] as Map<String, dynamic>;
        final waId = data['id'] as String;
        final created = _ensureRoom(
          acc,
          waId,
          data['name'] as String? ?? '',
          isDM: data['is_dm'] as bool? ?? true,
          altWaId: data['alt_id'] as String?,
        );
        // A genuinely new chat (e.g. someone messaged you for the first time):
        // load the default history window so it doesn't start empty.
        if (created) _maybeDefaultBackfill(acc, waId);

      case BridgeEventType.roomUpdated:
        // room_updated only refreshes existing rooms — never creates new ones.
        final waId = evt.data['room_id'] as String? ?? '';
        final name = evt.data['name'] as String? ?? '';
        final avatarUrl = evt.data['avatar_url'] as String? ?? '';
        final has = _waToMatrix.containsKey(_key(acc, waId));
        if (name.isNotEmpty && _looksLikeName(name) && has) {
          _pushNameUpdate(acc, waId, name);
        }
        if (avatarUrl.isNotEmpty && has) {
          _pushAvatarUpdate(acc, waId, avatarUrl);
        }

      case BridgeEventType.message:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final altRoomId = evt.data['alt_room_id'] as String?;
        final eventData = evt.data['event'] as Map<String, dynamic>;
        final isBackfill = eventData['is_backfill'] as bool? ?? false;
        final isNewRoom = !_waToMatrix.containsKey(_key(acc, waRoomId));
        var createdRoom = false;
        if (isNewRoom) {
          final isGroup = waRoomId.endsWith('@g.us');
          final senderName = eventData['sender_name'] as String?;
          final chatPhone = eventData['chat_phone'] as String?;
          final fallbackName = (!isGroup && senderName?.isNotEmpty == true)
              ? senderName!
              : (chatPhone?.isNotEmpty == true
                  ? chatPhone!
                  : waRoomId.split('@').first);
          createdRoom = _ensureRoom(acc, waRoomId, fallbackName,
              isDM: !isGroup, altWaId: altRoomId);
        }
        _pushMessage(acc, waRoomId, eventData);
        // New chat from an incoming message → load the default history window.
        if (createdRoom && !isBackfill) {
          _maybeDefaultBackfill(acc, waRoomId);
        }

      case BridgeEventType.backfill:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final events =
            (evt.data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        final clear = evt.data['clear'] as bool? ?? true;
        // Serialize backfill chunks so they're injected strictly in order
        // (oldest-first across chunks), and the clear happens once before them.
        _backfillChain = _backfillChain
            .then((_) => _pushBackfill(acc, waRoomId, events, clear: clear))
            .catchError((Object e, StackTrace s) =>
                Logs().w('[WaBridge] backfill chunk failed', e, s));

      case BridgeEventType.mediaReady:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final eventId = evt.data['event_id'] as String? ?? '';
        final filePath = evt.data['file_path'] as String? ?? '';
        final mimetype = evt.data['mimetype'] as String? ?? 'application/octet-stream';
        final size = (evt.data['size'] as num?)?.toInt() ?? 0;
        if (filePath.isNotEmpty && eventId.isNotEmpty &&
            _waToMatrix.containsKey(_key(acc, waRoomId))) {
          _pushMediaReady(acc, waRoomId, eventId, filePath, mimetype, size, evt.data);
        }

      case BridgeEventType.reaction:
        _pushReaction(acc, evt.data);

      case BridgeEventType.typing:
        _pushTyping(acc, evt.data);

      case BridgeEventType.receipt:
        _pushReceipt(acc, evt.data);

      case BridgeEventType.waCall:
        // ignore: unawaited_futures
        _handleWaCall(acc, evt.data);

      case BridgeEventType.historyProgress:
        final chats = (evt.data['chats'] as num?)?.toInt() ?? 0;
        final messages = (evt.data['messages'] as num?)?.toInt() ?? 0;
        var progress = (evt.data['progress'] as num?)?.toInt() ?? 0;
        final prev = _histProgress[acc];
        // Never let the percentage go backwards.
        if (prev != null && prev.progress > progress) progress = prev.progress;
        _histProgress[acc] =
            (chats: chats, messages: messages, progress: progress);

      default:
        break;
    }
  }

  // Latest history-sync progress per account, so the settings card survives
  // navigating away and back.
  final _histProgress =
      <String, ({int chats, int messages, int progress})>{};

  ({int chats, int messages, int progress})? historyProgress(String accountId) =>
      _histProgress[accountId];

  /// Incoming WhatsApp call: optionally auto-decline it (stop the ringing) and
  /// auto-reply with a "call me via this link" message.
  Future<void> _handleWaCall(
      String accountId, Map<String, dynamic> data) async {
    final autoReply = AppSettings.waCallAutoReply.value;
    final autoDecline = AppSettings.waCallAutoDecline.value;
    if (!autoReply && !autoDecline) return;

    final waRoomId = data['room_id'] as String? ?? '';
    final callerJid = data['caller_jid'] as String? ?? '';
    final callId = data['call_id'] as String? ?? '';

    // Stop the WhatsApp call ringing.
    if (autoDecline && callerJid.isNotEmpty && callId.isNotEmpty) {
      try {
        await TjenaBridge.instance
            .rejectCall(callerJid, callId, accountID: accountId);
      } catch (e) {
        Logs().w('[WaBridge] rejectCall failed: $e');
      }
    }

    // Send a "unreachable on WhatsApp — call me here" message with a call link.
    if (autoReply) {
      final client = _client;
      final matrixId = _waToMatrix[_key(accountId, waRoomId)];
      if (client == null || matrixId == null) return;
      try {
        final link = await requestCallLink(client);
        final text = AppSettings.waCallAutoReplyMessage.value.trim();
        await sendText(
          matrixId,
          text.isEmpty ? link.link : '$text\n${link.link}',
        );
      } catch (e) {
        Logs().w('[WaBridge] call auto-reply failed: $e');
      }
    }
  }

  // ── Space management ──────────────────────────────────────────────────────────

  /// Ensure this account's WhatsApp space exists so every WA chat can be parented
  /// to it, even before the phone number is known (the name is refined later).
  void _ensureSpace(String accountId) {
    if (_spaceIds[accountId] != null) return;
    _initSpace(accountId, _connectedPhones[accountId] ?? '');
  }

  void _initSpace(String accountId, String phone) {
    final client = _client;
    if (client?.userID == null) return;
    final name = phone.isNotEmpty ? 'WA-local ($phone)' : 'WhatsApp';
    final spaceRoomId = _spaceRoomIdFor(accountId);

    if (_spaceIds[accountId] != null) {
      _pushNameUpdate(accountId, spaceRoomId, name, isSpace: true);
      return;
    }
    _spaceIds[accountId] = spaceRoomId;
    final myUserId = client!.userID!;
    final now = DateTime.now();

    // ignore: unawaited_futures
    _inject(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        spaceRoomId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomCreate,
              content: {
                'creator': myUserId,
                'room_version': '10',
                'type': 'm.space',
              },
              senderId: myUserId,
              eventId: '\$wa_space_create_$accountId',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': name},
              senderId: myUserId,
              eventId: '\$wa_space_name_$accountId',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomMember,
              content: {'membership': 'join'},
              senderId: myUserId,
              eventId: '\$wa_space_member_$accountId',
              originServerTs: now,
              stateKey: myUserId,
            ),
            // Add this account's existing rooms as children.
            ...(_matrixToAccount.entries
                .where((e) => e.value == accountId)
                .map((e) => e.key)
                .map(
                  (mid) => MatrixEvent(
                    type: 'm.space.child',
                    content: {'via': ['local']},
                    senderId: myUserId,
                    eventId: '\$wa_spacechild_${_safe(mid)}',
                    originServerTs: now,
                    stateKey: mid,
                  ),
                )),
          ],
          timeline: TimelineUpdate(events: [], limited: false),
        ),
      }),
    ));
  }

  void _addRoomToSpace(String accountId, String matrixRoomId) {
    final spaceId = _spaceIds[accountId];
    final client = _client;
    if (spaceId == null || client?.userID == null) return;
    final ts = DateTime.now();
    // ignore: unawaited_futures
    _inject(SyncUpdate(
      nextBatch: client!.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        spaceId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: 'm.space.child',
              content: {'via': ['local']},
              senderId: client.userID!,
              eventId: '\$wa_spacechild_${_safe(matrixRoomId)}_${ts.millisecondsSinceEpoch}',
              originServerTs: ts,
              stateKey: matrixRoomId,
            ),
          ],
        ),
      }),
    ));
  }

  // ── Room lifecycle ────────────────────────────────────────────────────────────

  // Returns true if [s] looks like a real display name (contains at least one
  // letter). Phone numbers contain only digits, '+', '-', spaces and '(' ')';
  // they will return false, preventing the bridge from overwriting a good
  // name persisted in the DB with a bare number on restart.
  static bool _looksLikeName(String s) =>
      s.contains(RegExp(r'[A-Za-zÀ-žЀ-ӿ؀-ۿ]'));

  /// Load the user's configured default backfill window into a freshly-created
  /// chat, so a new chat doesn't start with only the one triggering message.
  void _maybeDefaultBackfill(String accountId, String waRoomId) {
    if (_defaultBackfillDays <= 0) return;
    // ignore: unawaited_futures
    TjenaBridge.instance
        .backfillFromCache(waRoomId, _defaultBackfillDays, accountID: accountId);
  }

  /// Returns true only when a brand-new room is created (not when the chat
  /// already exists or is aliased to an existing room) — callers use this to
  /// kick off the default backfill for genuinely new chats.
  bool _ensureRoom(String accountId, String waId, String name,
      {required bool isDM, String? altWaId}) {
    final mapKey = _key(accountId, waId);
    if (_waToMatrix.containsKey(mapKey)) {
      if (name.isNotEmpty && _looksLikeName(name)) {
        _pushNameUpdate(accountId, waId, name);
      }
      return false;
    }
    // If the LID↔phone-number counterpart already has a room (e.g. you started
    // the chat from the picker by phone number, and the reply arrives addressed
    // by LID), alias this JID to that existing room instead of creating a
    // duplicate. We only add the alias mapping; the room keeps its primary JID.
    if (altWaId != null && altWaId.isNotEmpty) {
      final altMatrix = _waToMatrix[_key(accountId, altWaId)];
      if (altMatrix != null) {
        _waToMatrix[mapKey] = altMatrix;
        // ignore: unawaited_futures
        _saveRoomMappings();
        if (name.isNotEmpty && _looksLikeName(name)) {
          _pushNameUpdate(accountId, altWaId, name);
        }
        return false;
      }
    }
    final matrixId = _toMatrixId(accountId, waId);
    // Safety: room already exists in the SDK (init missed it) — register mapping
    // without re-creating (would re-inject a member event / "joined" indicator).
    if (_client?.getRoomById(matrixId) != null) {
      _waToMatrix[mapKey] = matrixId;
      _matrixToWa[matrixId] = waId;
      _matrixToAccount[matrixId] = accountId;
      if (name.isNotEmpty && _looksLikeName(name)) {
        _pushNameUpdate(accountId, waId, name);
      }
      return false;
    }
    _waToMatrix[mapKey] = matrixId;
    _matrixToWa[matrixId] = waId;
    _matrixToAccount[matrixId] = accountId;
    // ignore: unawaited_futures
    _saveRoomMappings();
    _createRoom(accountId, matrixId, waId, name, isDM);
    // Always parent the chat to this account's WhatsApp space — even if we don't
    // know the phone number yet (picker chats are created from cache before the
    // connected-state event arrives). The space name is refined once connected.
    _ensureSpace(accountId);
    _addRoomToSpace(accountId, matrixId);
    // For groups, populate the participant list (member list + @-mentions).
    if (!isDM && waId.endsWith('@g.us')) {
      // ignore: unawaited_futures
      syncGroupMembers(matrixId);
    }
    return true;
  }

  void _createRoom(
      String accountId, String matrixId, String waId, String name, bool isDM) {
    final client = _client;
    if (client?.userID == null) return;
    final myUserId = client!.userID!;
    final now = DateTime.now();
    final token = client.prevBatch ?? '';
    final sid = _safe(waId);

    // ignore: unawaited_futures
    _inject(SyncUpdate(
      nextBatch: token,
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomCreate,
              content: {'creator': myUserId, 'room_version': '10'},
              senderId: myUserId,
              eventId: '\$wacreate_$sid',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': name.isNotEmpty ? name : waId.split('@').first},
              senderId: myUserId,
              eventId: '\$waname_$sid',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomMember,
              content: {'membership': 'join'},
              senderId: myUserId,
              eventId: '\$wamember_$sid',
              originServerTs: now,
              stateKey: myUserId,
            ),
            MatrixEvent(
              type: _bridgeStateType,
              content: {
                'wa_room_id': waId,
                'is_dm': isDM,
                'account_id': accountId,
              },
              senderId: myUserId,
              eventId: '\$wabridge_$sid',
              originServerTs: now,
              stateKey: '',
            ),
          ],
          timeline: TimelineUpdate(events: [], limited: false),
        ),
      }),
    ));
  }

  void _pushNameUpdate(String accountId, String waIdOrSpaceId, String name,
      {bool isSpace = false}) {
    final matrixId =
        isSpace ? waIdOrSpaceId : _waToMatrix[_key(accountId, waIdOrSpaceId)];
    if (matrixId == null) return;
    // Never override a name the user set manually.
    if (!isSpace && _customNames.containsKey(matrixId)) return;
    _injectName(matrixId, name);
  }

  void _injectName(String matrixId, String name) {
    final client = _client;
    if (client?.userID == null) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    // ignore: unawaited_futures
    _inject(SyncUpdate(
      nextBatch: client!.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': name},
              senderId: client.userID!,
              eventId: '\$waname_${_safe(matrixId)}_$ts',
              originServerTs: DateTime.now(),
              stateKey: '',
            ),
          ],
        ),
      }),
    ));
  }

  /// The user-set custom name for a WhatsApp room, or null if it uses the
  /// automatic (contact/group) name.
  String? customRoomName(String matrixRoomId) => _customNames[matrixRoomId];

  /// Manually set (or, with an empty name, clear) a WhatsApp room's name. A
  /// custom name persists and is never overwritten by automatic name refreshes.
  Future<void> setRoomName(String matrixRoomId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _customNames.remove(matrixRoomId);
      await _saveCustomNames();
      // Revert to the automatic name from the bridge.
      await refreshRoom(matrixRoomId);
      return;
    }
    _customNames[matrixRoomId] = trimmed;
    await _saveCustomNames();
    _injectName(matrixRoomId, trimmed);
  }

  Future<void> _saveCustomNames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_customNamesKey, jsonEncode(_customNames));
    } catch (e) {
      Logs().w('[WaBridge] save custom names failed: $e');
    }
  }

  Future<void> _pushAvatarUpdate(
      String accountId, String waId, String avatarHttpUrl) async {
    final matrixId = _waToMatrix[_key(accountId, waId)];
    final client = _client;
    if (matrixId == null || client?.userID == null) return;
    try {
      final response = await http.get(Uri.parse(avatarHttpUrl));
      if (response.statusCode != 200) return;
      final bytes = Uint8List.fromList(response.bodyBytes);
      // Store bytes in the Matrix database file cache under a fake mxc URI.
      // downloadMxcCached checks the cache first, so it never contacts a
      // homeserver for this URI.
      final mxcUri = Uri.parse('mxc://wa-local/${matrixId.hashCode.abs()}');
      await client!.database.storeFile(
        mxcUri,
        bytes,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      final ts = DateTime.now();
      // ignore: unawaited_futures
      _inject(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            state: [
              MatrixEvent(
                type: EventTypes.RoomAvatar,
                content: {'url': mxcUri.toString()},
                senderId: client.userID!,
                eventId: '\$waavatar_${_safe(waId)}_${ts.millisecondsSinceEpoch}',
                originServerTs: ts,
                stateKey: '',
              ),
            ],
          ),
        }),
      ));
    } catch (e, s) {
      Logs().d('[WaBridge] avatar fetch failed for $waId', e, s);
    }
  }

  // ── Event injection ───────────────────────────────────────────────────────────

  // Enqueue a handleSync so it runs strictly after all previously-enqueued
  // injections complete. Returns a future that completes when this update has
  // been applied. Errors are swallowed so one bad update can't stall the chain.
  Future<void> _inject(SyncUpdate update, {Direction? direction}) {
    final client = _client;
    if (client == null) return Future.value();
    final next =
        _injectChain.then((_) => client.handleSync(update, direction: direction));
    _injectChain = next.catchError((Object e, StackTrace s) {
      Logs().w('[WaBridge] inject failed', e, s);
    });
    return _injectChain;
  }

  /// Inject a batch of backfilled (historical) messages as a clean re-pull:
  /// first wipe the room's timeline (so there are no duplicates or the old
  /// "time jump"), then re-inject the whole window oldest-first as normal
  /// timeline events. This keeps everything in the initially-loaded set so it's
  /// visible immediately — virtual rooms can't paginate from a homeserver.
  /// Yields to the event loop every few messages so large backfills don't
  /// freeze the UI.
  Future<void> _pushBackfill(
      String accountId, String waRoomId, List<Map<String, dynamic>> events,
      {bool clear = true}) async {
    final matrixId = _waToMatrix[_key(accountId, waRoomId)];
    final client = _client;
    if (matrixId == null || client == null) return;

    // Clear the room timeline (only on the first chunk). limited:true makes the
    // SDK drop the room's cached events from its database AND clears any open
    // Timeline's in-memory list.
    if (clear) {
      await _inject(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            timeline: TimelineUpdate(events: const [], limited: true),
          ),
        }),
      ));
    }

    var n = 0;
    for (final e in events) {
      _pushMessage(accountId, waRoomId, e);
      // Let pending injections drain and the UI render a frame periodically.
      if (++n % 20 == 0) {
        await _injectChain;
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  // Placeholder bodies the Go bridge uses when a media message has no caption.
  static const _mediaPlaceholders = {
    '🖼 Image',
    '📹 Video',
    '🎵 Audio',
    '🌀 Sticker',
  };

  /// WhatsApp puts an attachment's caption in the message body. In Matrix an
  /// attachment's `body` is only treated as a caption when a separate `filename`
  /// is also present — so when there's a real caption, synthesize a filename so
  /// clients render the caption instead of hiding it.
  static void _applyCaption(
      Map<String, dynamic> content, String msgtype, String body) {
    if (msgtype != 'm.image' && msgtype != 'm.video' && msgtype != 'm.sticker') {
      return;
    }
    if (body.isEmpty || _mediaPlaceholders.contains(body)) return;
    content['filename'] = msgtype == 'm.video'
        ? 'video.mp4'
        : msgtype == 'm.sticker'
            ? 'sticker.webp'
            : 'image.jpg';
  }

  void _pushMessage(
      String accountId, String waRoomId, Map<String, dynamic> eventData) {
    final matrixId = _waToMatrix[_key(accountId, waRoomId)];
    final client = _client;
    if (matrixId == null || client?.userID == null) {
      Logs().w('[WaBridge] _pushMessage EARLY RETURN: acc=$accountId waRoomId=$waRoomId matrixId=$matrixId');
      return;
    }
    final myUserId = client!.userID!;

    final eventId = eventData['id'] as String? ??
        '\$wa_${DateTime.now().millisecondsSinceEpoch}';
    final rawSender = eventData['sender'] as String? ?? '@wa_unknown:local';
    final body = eventData['body'] as String? ?? '';
    final msgtype = eventData['msgtype'] as String? ?? 'm.text';
    final tsSeconds = eventData['ts'] as int? ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final isOwn = eventData['is_own'] as bool? ?? false;
    final isBackfill = eventData['is_backfill'] as bool? ?? false;
    final geoUri = eventData['geo_uri'] as String?;

    // Build content map — extended for location and media msgtypes.
    final content = <String, dynamic>{
      'msgtype': msgtype,
      'body': body,
    };
    if (geoUri != null) {
      content['geo_uri'] = geoUri;
    }
    // HTML formatted body for @-mentions (clickable name pills). Built by the Go
    // bridge from WhatsApp's mentionedJID list; present for live + backfill.
    final formattedBody = eventData['formatted_body'] as String?;
    if (formattedBody != null && formattedBody.isNotEmpty) {
      content['format'] = 'org.matrix.custom.html';
      content['formatted_body'] = formattedBody;
    }

    // For non-text, non-location msgtypes that need async media download,
    // remember enough to rebuild the event once media_ready arrives.
    final needsMedia = msgtype != 'm.text' && msgtype != 'm.location' && geoUri == null;
    if (needsMedia && !isBackfill) {
      _pendingMediaEvents[eventId] = {
        'waRoomId': waRoomId,
        'matrixId': matrixId,
        'sender': isOwn ? myUserId : rawSender,
        'ts': tsSeconds,
        'body': body,
        'msgtype': msgtype,
      };
    }
    // Backfilled media: the attachment was downloaded before, so its bytes are
    // still cached under this deterministic mxc URI — re-attach the URL so the
    // image/video/file shows instead of an empty bubble (and isn't lost on a
    // clean-reset "WA sync").
    final mediaMime = eventData['media_mime'] as String?;
    if (needsMedia && mediaMime != null && mediaMime.isNotEmpty) {
      content['url'] = 'mxc://wa-media/${eventId.replaceAll(r'$', '')}';
      final info = <String, dynamic>{'mimetype': mediaMime};
      final ms = (eventData['media_size'] as num?)?.toInt();
      if (ms != null && ms > 0) info['size'] = ms;
      // Backfilled videos: point at the preview thumbnail cached when the video
      // was first downloaded (falls back to a blur if it isn't cached).
      if (msgtype == 'm.video') {
        info['thumbnail_url'] =
            'mxc://wa-media/${eventId.replaceAll(r'$', '')}_thumb';
        info['thumbnail_info'] = {'mimetype': 'image/jpeg'};
      }
      content['info'] = info;
    }
    if (needsMedia) _applyCaption(content, msgtype, body);

    final senderName = eventData['sender_name'] as String?;
    final hasName = senderName != null && senderName.isNotEmpty;
    final isGroup = waRoomId.endsWith('@g.us');
    final isDM = !isGroup && !waRoomId.endsWith('@broadcast');
    final eventTs = DateTime.fromMillisecondsSinceEpoch(tsSeconds * 1000);

    // Build a SINGLE atomic sync carrying state (sender member + room name) and
    // the message timeline event together. Doing it in one handleSync avoids the
    // ordering/mapping races that previously left new chats nameless ("leerer
    // chat") and triggered ghost-profile lookups against the fake homeserver.
    final stateEvents = <MatrixEvent>[];

    // (1) Sender member with a join membership. Essential so the SDK resolves
    //     the ghost from local state instead of probing the homeserver.
    if (!isOwn) {
      final memberState = client
          .getRoomById(matrixId)
          ?.getState(EventTypes.RoomMember, rawSender);
      final currentMemberName =
          memberState?.content.tryGet<String>('displayname');
      // Update when the member is missing OR the name differs from the ACTUAL
      // stored name — so the message preview/sender always shows the latest
      // username (comparing against real state, not a cache that can drift).
      if (memberState == null || (hasName && currentMemberName != senderName)) {
        final nameKey = '$matrixId/$rawSender';
        if (hasName) _senderNames[nameKey] = senderName;
        final memberContent = <String, dynamic>{'membership': 'join'};
        if (hasName) memberContent['displayname'] = senderName;
        stateEvents.add(MatrixEvent(
          type: EventTypes.RoomMember,
          content: memberContent,
          senderId: rawSender,
          eventId: '\$wamember_${_safe(rawSender)}_${_safe(matrixId)}',
          originServerTs: eventTs,
          stateKey: rawSender,
        ));
      }
    }

    // (2) Guarantee a non-empty room name. An empty name makes the SDK show
    //     "leerer chat" (emptyChat fallback). Prefer the DM partner's push name;
    //     otherwise fall back to the bare number so the title is never blank. A
    //     real saved name from room_updated still wins (_looksLikeName guard).
    final currentName = client.getRoomById(matrixId)?.name ?? '';
    final chatPhone = eventData['chat_phone'] as String?;
    final hasCustomName = _customNames.containsKey(matrixId);
    String? nameToSet;
    if (hasCustomName) {
      // User set a manual name — never override it.
      nameToSet = null;
    } else if (!isOwn && hasName && isDM && !_looksLikeName(currentName)) {
      nameToSet = senderName;
    } else if (!_looksLikeName(currentName)) {
      // No real name yet — prefer the resolved phone number (LID→PN) over the
      // raw LID ident; fall back to the JID's user part only if unavailable.
      nameToSet = (chatPhone?.isNotEmpty == true)
          ? chatPhone!
          : waRoomId.split('@').first;
    }
    if (nameToSet != null && nameToSet.isNotEmpty && nameToSet != currentName) {
      stateEvents.add(MatrixEvent(
        type: EventTypes.RoomName,
        content: {'name': nameToSet},
        senderId: myUserId,
        eventId: '\$waname_${_safe(waRoomId)}_${DateTime.now().millisecondsSinceEpoch}',
        originServerTs: eventTs,
        stateKey: '',
      ));
    }
    Logs().i('[WaBridge] NAME room=$waRoomId matrixId=$matrixId isDM=$isDM '
        'hasName=$hasName senderName="$senderName" currentName="$currentName" '
        'nameToSet="$nameToSet" stateEvents=${stateEvents.length}');

    // (3) The message itself (media gets a URL-less placeholder; media_ready
    //     re-injects with the URL later). Serialized via _inject so it never
    //     races the placeholder.
    // ignore: unawaited_futures
    _inject(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          state: stateEvents.isEmpty ? null : stateEvents,
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: EventTypes.Message,
                content: content,
                senderId: isOwn ? myUserId : rawSender,
                eventId: eventId,
                originServerTs: eventTs,
                roomId: matrixId,
              ),
            ],
            limited: false,
          ),
          unreadNotifications: (isOwn || isBackfill)
              ? null
              : UnreadNotificationCounts(notificationCount: 1),
        ),
      }),
    ));
    // Read back the room name once the sync has applied, to see whether the
    // RoomName state actually stuck in the SDK.
    _injectChain.then((_) {
      final r = client.getRoomById(matrixId);
      Logs().i('[WaBridge] POST-INJECT room=$waRoomId name="${r?.name}" '
          'members=${r?.getParticipants().length} displayname="${r?.getLocalizedDisplayname()}"');
    });
  }

  Future<void> _pushMediaReady(
    String accountId,
    String waRoomId,
    String eventId,
    String filePath,
    String mimetype,
    int size,
    Map<String, dynamic> payload,
  ) async {
    // Use event data embedded in the payload (primary), fall back to pending map.
    final pending = _pendingMediaEvents.remove(eventId);
    final matrixId = _waToMatrix[_key(accountId, waRoomId)];
    final client = _client;
    if (matrixId == null || client?.userID == null) {
      Logs().w('[WaBridge] _pushMediaReady ABORT: matrixId=$matrixId userID=${client?.userID}');
      return;
    }
    try {
      final base = eventId.replaceAll(r'$', '');
      final mxcUri = Uri.parse('mxc://wa-media/$base');
      final thumbMxc = 'mxc://wa-media/${base}_thumb';

      // Store the preview thumbnail if this update carries one (sent early, so
      // videos show a preview before/independently of the full download).
      final thumbPath = payload['thumb_path'] as String?;
      if (thumbPath != null && thumbPath.isNotEmpty) {
        try {
          final tb = await File(thumbPath).readAsBytes();
          await client!.database.storeFile(
              Uri.parse(thumbMxc), tb, DateTime.now().millisecondsSinceEpoch ~/ 1000);
        } catch (e) {
          Logs().w('[WaBridge] thumb store failed: $e');
        }
        try {
          await File(thumbPath).delete();
        } catch (_) {}
      }

      // file_path is empty for a thumbnail-only update (no full attachment yet).
      final thumbOnly = filePath.isEmpty;
      Uint8List? bytes;
      if (!thumbOnly) {
        bytes = await File(filePath).readAsBytes();
        await client!.database.storeFile(
            mxcUri, bytes, DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }

      // Prefer data embedded in the media_ready payload; fall back to pending.
      final sender = payload['sender'] as String?
          ?? pending?['sender'] as String?
          ?? '@wa_unknown:local';
      final rawTs = payload['ts'] ?? pending?['ts'];
      final ts = (rawTs as num?)?.toInt()
          ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
      final body = payload['body'] as String?
          ?? pending?['body'] as String?
          ?? '';
      final msgtype = payload['msgtype'] as String?
          ?? pending?['msgtype'] as String?
          ?? 'm.image';
      final isOwn = payload['is_own'] as bool?
          ?? pending?['is_own'] as bool?
          ?? false;
      final myUserId = client!.userID!;

      if (bytes != null) _autoSaveMedia(bytes, body, msgtype, mimetype);

      final info = <String, dynamic>{};
      if (!thumbOnly) {
        info['mimetype'] = mimetype;
        info['size'] = size;
      }
      final tw = (payload['thumb_w'] as num?)?.toInt();
      final th = (payload['thumb_h'] as num?)?.toInt();
      if (tw != null && tw > 0) info['w'] = tw;
      if (th != null && th > 0) info['h'] = th;
      // Videos show a separate preview thumbnail (deterministic mxc, stored here
      // or by the earlier thumbnail-only update). Images render their full
      // attachment directly.
      if (msgtype == 'm.video') {
        info['thumbnail_url'] = thumbMxc;
        info['thumbnail_info'] = {'mimetype': 'image/jpeg'};
      }
      final mediaContent = <String, dynamic>{
        'msgtype': msgtype,
        'body': body,
        if (!thumbOnly) 'url': mxcUri.toString(),
        'info': info,
      };
      _applyCaption(mediaContent, msgtype, body);
      await _inject(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: [
                MatrixEvent(
                  type: EventTypes.Message,
                  content: mediaContent,
                  senderId: isOwn ? myUserId : sender,
                  eventId: eventId,
                  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
                  roomId: matrixId,
                ),
              ],
              limited: false,
            ),
            // Don't bump unread on the thumbnail-only preview update.
            unreadNotifications: (isOwn || thumbOnly)
                ? null
                : UnreadNotificationCounts(notificationCount: 1),
          ),
        }),
      ));
      // Clean up the full-media temp file (thumbnail-only carries none).
      if (!thumbOnly) {
        try { await File(filePath).delete(); } catch (_) {}
      }
    } catch (e, s) {
      Logs().w('[WaBridge] media_ready inject failed for $eventId', e, s);
    }
  }

  void _pushReaction(String accountId, Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[_key(accountId, waRoomId)];
    final client = _client;
    if (matrixId == null || client == null || client.userID == null) return;

    final eventId = data['id'] as String? ??
        '\$wa_react_${DateTime.now().millisecondsSinceEpoch}';
    final rawSender = data['sender'] as String? ?? '@wa_unknown:local';
    final targetId = data['target_id'] as String? ?? '';
    final emoji = data['emoji'] as String? ?? '';
    final isOwn = rawSender.contains(_connectedPhones[accountId] ?? '__none__');

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: 'm.reaction',
                content: {
                  'm.relates_to': {
                    'rel_type': 'm.annotation',
                    'event_id': '\$wa_$targetId',
                    'key': emoji,
                  },
                },
                senderId: isOwn ? client.userID! : rawSender,
                eventId: eventId,
                originServerTs: DateTime.now(),
                roomId: matrixId,
              ),
            ],
            limited: false,
          ),
        ),
      }),
    ));
  }

  void _pushTyping(String accountId, Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[_key(accountId, waRoomId)];
    final client = _client;
    if (matrixId == null) return;

    final userId = data['user_id'] as String? ?? '@wa_unknown:local';
    final typing = data['typing'] as bool? ?? false;

    // ignore: unawaited_futures
    client?.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          ephemeral: [
            BasicEvent(
              type: 'm.typing',
              content: {
                'user_ids': typing ? [userId] : <String>[],
              },
            ),
          ],
        ),
      }),
    ));
  }

  void _pushReceipt(String accountId, Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[_key(accountId, waRoomId)];
    final client = _client;
    if (matrixId == null) return;

    final userId = data['user_id'] as String? ?? '@wa_unknown:local';
    final eventId = data['event_id'] as String? ?? '';
    final ts = data['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (eventId.isEmpty) return;

    // ignore: unawaited_futures
    client?.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          ephemeral: [
            BasicEvent(
              type: 'm.receipt',
              content: {
                eventId: {
                  'm.read': {
                    userId: {'ts': ts},
                  },
                },
              },
            ),
          ],
        ),
      }),
    ));
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

  static void _autoSaveMedia(
      Uint8List bytes, String body, String msgtype, String mimetype) {
    if (kIsWeb || !PlatformInfos.isMobile) return;
    if (!AppSettings.autoSaveMedia.value) return;
    final isImage = msgtype == 'm.image';
    final isVideo = msgtype == 'm.video';
    if (!isImage && !isVideo) return;
    final file = isImage
        ? MatrixImageFile(bytes: bytes, name: body)
        : MatrixVideoFile(bytes: bytes, name: body);
    final fileName = MatrixFileExtension.galleryName(
      'wa',
      mimeType: mimetype,
      originalName: body,
      video: isVideo,
    );
    file.saveToGallery(fileName: fileName).catchError((_) => false);
  }
}
