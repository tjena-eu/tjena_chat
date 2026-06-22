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
import 'platform_infos.dart';

/// Converts WA bridge events into virtual Matrix rooms injected via handleSync.
/// Once injected, FluffyChat treats WA rooms identically to real Matrix rooms.
class WaMatrixBridge {
  WaMatrixBridge._();
  static final instance = WaMatrixBridge._();

  Client? _client;

  // Bidirectional WA JID ↔ Matrix room ID mapping
  final _waToMatrix = <String, String>{};
  final _matrixToWa = <String, String>{};

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

  String? _spaceId;
  String? _connectedPhone;

  // Cached in memory for the hot path (new-room lazy backfill); loaded in init.
  int _defaultBackfillDays = 30;

  static const _bridgeStateType = 'org.tjena.bridge.local';
  static const _spaceRoomId = '!wa_space_local:local';

  static String _toMatrixId(String waRoomId) =>
      '!wa_${waRoomId.replaceAll('@', '_')}:local';

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

  Future<void> init(Client client) async {
    _client = client;

    // ① Load from SharedPreferences — fast, reliable, survives process kills.
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString(_roomMappingsKey);
      if (str != null) {
        final raw = jsonDecode(str) as Map<String, dynamic>;
        for (final e in raw.entries) {
          _waToMatrix[e.key] = e.value as String;
          _matrixToWa[e.value as String] = e.key;
        }
      }
    } catch (e) {
      Logs().w('[WaBridge] load room mappings failed: $e');
    }

    // ② Supplement from client.rooms (covers first-ever install and space room).
    for (final room in client.rooms) {
      if (room.id == _spaceRoomId) {
        _spaceId = _spaceRoomId;
        continue;
      }
      var waId = room.getState(_bridgeStateType)?.content['wa_room_id'] as String?;
      waId ??= _waIdFromRoomId(room.id);
      if (waId != null && !_waToMatrix.containsKey(waId)) {
        _waToMatrix[waId] = room.id;
        _matrixToWa[room.id] = waId;
      }
    }

    // ③ Persist the complete mapping back so next restart is instantaneous.
    // ignore: unawaited_futures
    _saveRoomMappings();

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
      if (room.id == _spaceRoomId) continue;
      var waId = room.getState(_bridgeStateType)?.content['wa_room_id'] as String?;
      waId ??= _waIdFromRoomId(room.id);
      if (waId == null) continue;
      if (!_waToMatrix.containsKey(waId)) {
        _waToMatrix[waId] = room.id;
        _matrixToWa[room.id] = waId;
      }
      final n = room.name;
      if (n.isEmpty || n.contains('@') || n == room.id) {
        _pushNameUpdate(waId, waId.split('@').first);
        repaired++;
      }
    }
    Logs().w('[WaBridge] name repair ($reason): scanned ${client.rooms.length} rooms, repaired $repaired');
  }

  bool isWaRoom(String matrixRoomId) => _matrixToWa.containsKey(matrixRoomId);
  String? waRoomId(String matrixRoomId) => _matrixToWa[matrixRoomId];
  String? matrixRoomId(String waRoomId) => _waToMatrix[waRoomId];

  /// Returns the Matrix room ID for [rawPhone], creating a virtual WA room
  /// if one doesn't exist yet. Returns null only if the bridge is not linked.
  String? ensureChatForPhone(String rawPhone) {
    if (!isLinked) return null;
    final phone = rawPhone.replaceAll(RegExp(r'[\s+\-()]'), '');
    final jid = '$phone@s.whatsapp.net';
    if (!_waToMatrix.containsKey(jid)) {
      _ensureRoom(jid, '+$phone', isDM: true);
    }
    return _waToMatrix[jid];
  }
  // True if connected now, OR if rooms from a previous session still exist —
  // the latter means the bridge was linked before but the state event hasn't
  // fired yet this session (bridge still connecting at app start).
  bool get isLinked => _connectedPhone != null || _waToMatrix.isNotEmpty;
  String? get connectedPhone => _connectedPhone;
  String? matrixRoomIdForPhone(String phone) {
    final jid = '${phone.replaceAll('+', '').replaceAll(' ', '')}@s.whatsapp.net';
    return _waToMatrix[jid];
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
    await TjenaBridge.instance.sendText(waId, eventId, text);
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
      await TjenaBridge.instance.sendMedia(waId, eventId, mimeType, bytes);
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
      await TjenaBridge.instance.sendLocation(waId, lat, lon);
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
    final n = _client?.getRoomById(matrixRoomId)?.name ?? '';
    if (n.isEmpty || n.contains('@') || n == matrixRoomId) {
      _pushNameUpdate(waId, waId.split('@').first);
    }
    try {
      await TjenaBridge.instance.refreshRoom(waId);
    } catch (e) {
      Logs().w('[WaBridge] refreshRoom failed: $e');
    }
  }

  /// Pull WhatsApp message history for a chat going back [days] days from the
  /// local cache (populated by the link-time history sync). Reliable — no
  /// network anchor needed. Messages arrive as backfill events.
  Future<void> requestBackfill(String matrixRoomId, int days) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) throw Exception('not a WhatsApp chat');
    await TjenaBridge.instance.backfillFromCache(waId, days);
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
  Future<List<Map<String, dynamic>>> listChatsWithStatus() async {
    final byJid = <String, Map<String, dynamic>>{};

    // Cached chats first — these carry last_ts (recency) for every chat.
    for (final c in await TjenaBridge.instance.listCachedChats()) {
      final jid = c['jid'] as String? ?? '';
      if (jid.isEmpty) continue;
      byJid[jid] = {
        'jid': jid,
        'name': c['name'] ?? '',
        'is_group': c['is_group'] ?? false,
        'phone': c['phone'] ?? '',
        'last_activity': ((c['last_ts'] as num?)?.toInt() ?? 0) * 1000,
      };
    }
    // Merge in contacts/groups without cached history.
    for (final c in await TjenaBridge.instance.listChats()) {
      final jid = c['jid'] as String? ?? '';
      if (jid.isEmpty || byJid.containsKey(jid)) continue;
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
      c['synced'] = _waToMatrix.containsKey(c['jid']);
    }
    return out;
  }

  /// Fetch a chat's WhatsApp profile-picture URL (direct CDN https link).
  Future<String> chatAvatarUrl(String jid) =>
      TjenaBridge.instance.getChatAvatarUrl(jid);

  /// Create a room for [jid] and backfill [days] days from the local cache.
  Future<void> syncChat(String jid, String name, bool isGroup, int days) async {
    final displayName = name.isNotEmpty ? name : jid.split('@').first;
    _ensureRoom(jid, displayName, isDM: !isGroup);
    if (days > 0) {
      // ignore: unawaited_futures
      TjenaBridge.instance.backfillFromCache(jid, days);
    }
    final mid = _waToMatrix[jid];
    if (mid != null) {
      // ignore: unawaited_futures
      refreshRoom(mid); // real name + photo
    }
  }

  /// Create rooms + backfill [days] for every cached chat (link-mode "all").
  Future<int> syncAllCachedChats(int days) async {
    final chats = await TjenaBridge.instance.listCachedChats();
    for (final c in chats) {
      final jid = c['jid'] as String? ?? '';
      if (jid.isEmpty || _waToMatrix.containsKey(jid)) continue;
      await syncChat(
        jid,
        c['name'] as String? ?? '',
        c['is_group'] as bool? ?? false,
        days,
      );
    }
    return chats.length;
  }

  /// Remove a chat's room from the bridge (keeps WhatsApp linked).
  Future<void> unsyncChat(String jid) async {
    final mid = _waToMatrix[jid];
    if (mid == null) return;
    final client = _client;
    if (client != null) {
      try { await client.database.forgetRoom(mid); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == mid);
      client.archivedRooms.removeWhere((r) => r.room.id == mid);
    }
    _waToMatrix.remove(jid);
    _matrixToWa.remove(mid);
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
      await TjenaBridge.instance.markRead(waId, lastEventId ?? '');
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
    try {
      await TjenaBridge.instance.sendReaction(waId, targetWaId, emoji);
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
      await TjenaBridge.instance.sendRedaction(waId, targetWaId);
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
        .setTyping(waId, typing: typing)
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
    // Also remove the space room.
    if (_spaceId != null) {
      try { await client.database.forgetRoom(_spaceId!); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == _spaceId);
      _spaceId = null;
    }
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

  // ── Bridge event dispatch ─────────────────────────────────────────────────────

  void _onBridgeEvent(BridgeEvent evt) {
    try {
      _onBridgeEventInner(evt);
    } catch (e, s) {
      Logs().w('[WaBridge] unhandled event error (${evt.type})', e, s);
    }
  }

  void _onBridgeEventInner(BridgeEvent evt) {
    switch (evt.type) {
      case BridgeEventType.state:
        final phone = evt.data['phone'] as String? ?? '';
        final connected = evt.data['connected'] as bool? ?? false;
        if (connected && phone.isNotEmpty && phone != _connectedPhone) {
          _connectedPhone = phone;
          _initSpace(phone);
        }

      case BridgeEventType.roomCreated:
        final data = evt.data['room'] as Map<String, dynamic>;
        _ensureRoom(
          data['id'] as String,
          data['name'] as String? ?? '',
          isDM: data['is_dm'] as bool? ?? true,
        );

      case BridgeEventType.roomUpdated:
        // room_updated only refreshes existing rooms — never creates new ones.
        // (Creating from room_updated would cause spurious DM rooms for every
        // group-chat member whose PushName event fires.)
        final waId = evt.data['room_id'] as String? ?? '';
        final name = evt.data['name'] as String? ?? '';
        final avatarUrl = evt.data['avatar_url'] as String? ?? '';
        if (name.isNotEmpty && _looksLikeName(name) && _waToMatrix.containsKey(waId)) {
          _pushNameUpdate(waId, name);
        }
        if (avatarUrl.isNotEmpty && _waToMatrix.containsKey(waId)) {
          _pushAvatarUpdate(waId, avatarUrl);
        }

      case BridgeEventType.message:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final eventData = evt.data['event'] as Map<String, dynamic>;
        final isBackfill = eventData['is_backfill'] as bool? ?? false;
        final isNewRoom = !_waToMatrix.containsKey(waRoomId);
        if (isNewRoom) {
          final isGroup = waRoomId.endsWith('@g.us');
          final senderName = eventData['sender_name'] as String?;
          // chat_phone is the resolved phone number (LID chats resolve LID→PN in
          // Go), a far friendlier fallback than the raw LID ident number.
          final chatPhone = eventData['chat_phone'] as String?;
          // Only seed a DM room with the sender's push name — for a group the
          // sender is a member, not the room, so naming the group after them is
          // wrong. Groups get a temporary name until room_updated delivers the
          // real group name (via Go GetGroupInfo).
          final fallbackName = (!isGroup && senderName?.isNotEmpty == true)
              ? senderName!
              : (chatPhone?.isNotEmpty == true
                  ? chatPhone!
                  : waRoomId.split('@').first);
          _ensureRoom(
            waRoomId,
            fallbackName,
            isDM: !isGroup,
          );
        }
        _pushMessage(waRoomId, eventData);
        // A brand-new chat surfaced by a *live* message (silent link mode, or a
        // chat that appeared after linking): pull its recent history from the
        // cache so it doesn't start empty. Skipped for backfilled messages to
        // avoid re-entrancy.
        if (isNewRoom && !isBackfill && _defaultBackfillDays > 0) {
          // ignore: unawaited_futures
          TjenaBridge.instance.backfillFromCache(waRoomId, _defaultBackfillDays);
        }

      case BridgeEventType.backfill:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final events =
            (evt.data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final e in events) {
          _pushMessage(waRoomId, e);
        }

      case BridgeEventType.mediaReady:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final eventId = evt.data['event_id'] as String? ?? '';
        final filePath = evt.data['file_path'] as String? ?? '';
        final mimetype = evt.data['mimetype'] as String? ?? 'application/octet-stream';
        final size = (evt.data['size'] as num?)?.toInt() ?? 0;
        Logs().d('[WaBridge] media_ready: room=$waRoomId ev=$eventId fp=$filePath size=$size knownRoom=${_waToMatrix.containsKey(waRoomId)}');
        if (filePath.isNotEmpty && eventId.isNotEmpty && _waToMatrix.containsKey(waRoomId)) {
          _pushMediaReady(waRoomId, eventId, filePath, mimetype, size, evt.data);
        } else {
          Logs().w('[WaBridge] media_ready SKIPPED: fp.empty=${filePath.isEmpty} ev.empty=${eventId.isEmpty} noRoom=${!_waToMatrix.containsKey(waRoomId)}');
        }

      case BridgeEventType.reaction:
        _pushReaction(evt.data);

      case BridgeEventType.typing:
        _pushTyping(evt.data);

      case BridgeEventType.receipt:
        _pushReceipt(evt.data);

      default:
        break;
    }
  }

  // ── Space management ──────────────────────────────────────────────────────────

  void _initSpace(String phone) {
    final client = _client;
    if (client?.userID == null) return;
    final name = 'WA-local ($phone)';

    if (_spaceId != null) {
      // Space already exists — just update the name.
      _pushNameUpdate(_spaceId!, name, isSpace: true);
      return;
    }
    _spaceId = _spaceRoomId;
    final myUserId = client!.userID!;
    final now = DateTime.now();

    // ignore: unawaited_futures
    _inject(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        _spaceRoomId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomCreate,
              content: {
                'creator': myUserId,
                'room_version': '10',
                'type': 'm.space',
              },
              senderId: myUserId,
              eventId: '\$wa_space_create',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': name},
              senderId: myUserId,
              eventId: '\$wa_space_name',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomMember,
              content: {'membership': 'join'},
              senderId: myUserId,
              eventId: '\$wa_space_member',
              originServerTs: now,
              stateKey: myUserId,
            ),
            // Add all existing WA rooms as children.
            ..._waToMatrix.values.map(
              (mid) => MatrixEvent(
                type: 'm.space.child',
                content: {'via': ['local']},
                senderId: myUserId,
                eventId: '\$wa_spacechild_${_safe(mid)}',
                originServerTs: now,
                stateKey: mid,
              ),
            ),
          ],
          timeline: TimelineUpdate(events: [], limited: false),
        ),
      }),
    ));
  }

  void _addRoomToSpace(String matrixRoomId) {
    final spaceId = _spaceId;
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

  void _ensureRoom(String waId, String name, {required bool isDM}) {
    if (_waToMatrix.containsKey(waId)) {
      // Only overwrite the stored name when the incoming name looks like a
      // real contact name.  On restart the contacts DB is often empty, so
      // ensureRoom arrives with a bare phone number; we must not clobber the
      // good name that was persisted from the previous session.
      if (name.isNotEmpty && _looksLikeName(name)) _pushNameUpdate(waId, name);
      return;
    }
    final matrixId = _toMatrixId(waId);
    // Safety: if the room already exists in the SDK's room list (e.g. init
    // missed it because the bridge state event wasn't loaded), register the
    // mapping without re-creating the room — that would re-inject a member
    // event and show a spurious "joined" indicator in the UI.
    if (_client?.getRoomById(matrixId) != null) {
      _waToMatrix[waId] = matrixId;
      _matrixToWa[matrixId] = waId;
      if (name.isNotEmpty && _looksLikeName(name)) _pushNameUpdate(waId, name);
      return;
    }
    _waToMatrix[waId] = matrixId;
    _matrixToWa[matrixId] = waId;
    // Persist so the mapping survives the next process restart.
    // ignore: unawaited_futures
    _saveRoomMappings();
    _createRoom(matrixId, waId, name, isDM);
    if (_spaceId == null && _connectedPhone != null) {
      _initSpace(_connectedPhone!);
    }
    _addRoomToSpace(matrixId);
  }

  void _createRoom(String matrixId, String waId, String name, bool isDM) {
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
              content: {'wa_room_id': waId, 'is_dm': isDM},
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

  void _pushNameUpdate(String waIdOrSpaceId, String name, {bool isSpace = false}) {
    final matrixId = isSpace ? waIdOrSpaceId : _waToMatrix[waIdOrSpaceId];
    final client = _client;
    if (matrixId == null || client?.userID == null) return;
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
              eventId: '\$waname_${_safe(waIdOrSpaceId)}_$ts',
              originServerTs: DateTime.now(),
              stateKey: '',
            ),
          ],
        ),
      }),
    ));
  }

  Future<void> _pushAvatarUpdate(String waId, String avatarHttpUrl) async {
    final matrixId = _waToMatrix[waId];
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
  Future<void> _inject(SyncUpdate update) {
    final client = _client;
    if (client == null) return Future.value();
    final next = _injectChain.then((_) => client.handleSync(update));
    _injectChain = next.catchError((Object e, StackTrace s) {
      Logs().w('[WaBridge] inject failed', e, s);
    });
    return _injectChain;
  }

  void _pushMessage(String waRoomId, Map<String, dynamic> eventData) {
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null || client?.userID == null) {
      Logs().w('[WaBridge] _pushMessage EARLY RETURN: waRoomId=$waRoomId matrixId=$matrixId');
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
      final nameKey = '$matrixId/$rawSender';
      final memberExists =
          client.getRoomById(matrixId)?.getState(EventTypes.RoomMember, rawSender) != null;
      final nameChanged = hasName && _senderNames[nameKey] != senderName;
      if (!memberExists || nameChanged) {
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
    String? nameToSet;
    if (!isOwn && hasName && isDM && !_looksLikeName(currentName)) {
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
    String waRoomId,
    String eventId,
    String filePath,
    String mimetype,
    int size,
    Map<String, dynamic> payload,
  ) async {
    // Use event data embedded in the payload (primary), fall back to pending map.
    final pending = _pendingMediaEvents.remove(eventId);
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null || client?.userID == null) {
      Logs().w('[WaBridge] _pushMediaReady ABORT: matrixId=$matrixId userID=${client?.userID}');
      return;
    }
    try {
      Logs().d('[WaBridge] _pushMediaReady reading $filePath');
      final bytes = await File(filePath).readAsBytes();
      Logs().d('[WaBridge] _pushMediaReady read ${bytes.length} bytes');
      final mxcUri = Uri.parse('mxc://wa-media/${eventId.replaceAll(r'$', '')}');
      await client!.database.storeFile(
        mxcUri,
        bytes,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      Logs().d('[WaBridge] _pushMediaReady storeFile done for $mxcUri');

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
      final myUserId = client.userID!;

      _autoSaveMedia(bytes, body, msgtype);

      Logs().d('[WaBridge] _pushMediaReady injecting $eventId into $matrixId url=$mxcUri size=$size');
      // Re-inject the same event ID with content['url'] added. Serialized via
      // _inject so it always lands AFTER the _pushMessage placeholder, never
      // before — so the URL can't be clobbered.
      await _inject(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: [
                MatrixEvent(
                  type: EventTypes.Message,
                  content: {
                    'msgtype': msgtype,
                    'body': body,
                    'url': mxcUri.toString(),
                    'info': {'mimetype': mimetype, 'size': size},
                  },
                  senderId: isOwn ? myUserId : sender,
                  eventId: eventId,
                  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
                  roomId: matrixId,
                ),
              ],
              limited: false,
            ),
            unreadNotifications: isOwn
                ? null
                : UnreadNotificationCounts(notificationCount: 1),
          ),
        }),
      ));
      Logs().d('[WaBridge] _pushMediaReady injected $eventId ok');
      // Clean up the temp file written by the Go bridge.
      try { await File(filePath).delete(); } catch (_) {}
    } catch (e, s) {
      Logs().w('[WaBridge] media_ready inject failed for $eventId', e, s);
    }
  }

  void _pushReaction(Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null || client == null || client.userID == null) return;

    final eventId = data['id'] as String? ??
        '\$wa_react_${DateTime.now().millisecondsSinceEpoch}';
    final rawSender = data['sender'] as String? ?? '@wa_unknown:local';
    final targetId = data['target_id'] as String? ?? '';
    final emoji = data['emoji'] as String? ?? '';
    final isOwn = rawSender.contains(_connectedPhone ?? '__none__');

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

  void _pushTyping(Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[waRoomId];
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

  void _pushReceipt(Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[waRoomId];
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

  static void _autoSaveMedia(Uint8List bytes, String body, String msgtype) {
    if (kIsWeb || !PlatformInfos.isMobile) return;
    if (!AppSettings.autoSaveMedia.value) return;
    final isImage = msgtype == 'm.image';
    final isVideo = msgtype == 'm.video';
    if (!isImage && !isVideo) return;
    final file = isImage
        ? MatrixImageFile(bytes: bytes, name: body)
        : MatrixVideoFile(bytes: bytes, name: body);
    file.saveToGallery().catchError((_) => false);
  }
}
