// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

// Personal ("own") WhatsApp bridge support: the bridge runs in the tjena
// Bridge app on a phone at home and reaches Synapse through the gateway at
// wap.tjena.eu. This file holds the shared logic; UI is in
// pages/settings_bridges/own_bridge_page.dart.

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

const whatsAppBridgeAccountDataType = 'eu.tjena.whatsapp_bridge';
const defaultBridgeGateway = 'https://wap.tjena.eu';
const doublePuppetDeviceName = 'WhatsApp bridge double puppet (home)';

/// Which WhatsApp bridge the user uses. Stored in account data so all of the
/// user's devices agree.
class WhatsAppBridgeConfig {
  /// 'server' (shared tjena bridge) or 'own' (personal bridge at home).
  final String mode;
  final String? ownBot;
  final String? slot;
  final String gateway;
  final int offlineNotifyMinutes;

  const WhatsAppBridgeConfig({
    this.mode = 'server',
    this.ownBot,
    this.slot,
    this.gateway = defaultBridgeGateway,
    this.offlineNotifyMinutes = 30,
  });

  bool get usesOwn => mode == 'own' && ownBot != null;

  static String serverBot(Client c) =>
      '@whatsappbot:${c.userID?.domain ?? 'tjena.eu'}';

  String activeBot(Client c) => usesOwn ? ownBot! : serverBot(c);

  static WhatsAppBridgeConfig of(Client c) {
    final j = c.accountData[whatsAppBridgeAccountDataType]?.content ?? {};
    return WhatsAppBridgeConfig(
      mode: j['mode'] as String? ?? 'server',
      ownBot: j['own_bot'] as String?,
      slot: j['slot'] as String?,
      gateway: j['gateway'] as String? ?? defaultBridgeGateway,
      offlineNotifyMinutes: j['offline_notify_minutes'] as int? ?? 30,
    );
  }

  WhatsAppBridgeConfig copyWith({
    String? mode,
    String? ownBot,
    String? slot,
    String? gateway,
    int? offlineNotifyMinutes,
    bool clearOwn = false,
  }) => WhatsAppBridgeConfig(
    mode: mode ?? this.mode,
    ownBot: clearOwn ? null : ownBot ?? this.ownBot,
    slot: clearOwn ? null : slot ?? this.slot,
    gateway: gateway ?? this.gateway,
    offlineNotifyMinutes: offlineNotifyMinutes ?? this.offlineNotifyMinutes,
  );

  Future<void> save(Client c) =>
      c.setAccountData(c.userID!, whatsAppBridgeAccountDataType, {
        'mode': mode,
        if (ownBot != null) 'own_bot': ownBot,
        if (slot != null) 'slot': slot,
        'gateway': gateway,
        'offline_notify_minutes': offlineNotifyMinutes,
      });
}

class OwnBridgeStatus {
  final String slot;
  final String botMxid;
  final bool active;
  final bool connected;
  final DateTime? connectedSince;
  final DateTime? lastSeen;
  final DateTime? lastEvent;

  OwnBridgeStatus.fromJson(Map<String, dynamic> j)
    : slot = j['slot'] as String? ?? '',
      botMxid = j['bot_mxid'] as String? ?? '',
      active = j['active'] == true,
      connected = j['connected'] == true,
      connectedSince = DateTime.tryParse(j['connected_since'] as String? ?? ''),
      lastSeen = DateTime.tryParse(j['last_seen'] as String? ?? ''),
      lastEvent = DateTime.tryParse(j['last_event'] as String? ?? '');

  /// How long the bridge has been offline (null if online or unknown).
  Duration? get offlineFor => connected || lastSeen == null
      ? null
      : DateTime.now().difference(lastSeen!.toLocal());
}

class PersonalBridgeException implements Exception {
  final String message;
  final int status;
  PersonalBridgeException(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

/// Calls to the gateway's provisioner. Authenticated with a short-lived Matrix
/// OpenID token, so the tjena app's access token never reaches the gateway.
class PersonalBridgeApi {
  static String? _openIdToken;
  static DateTime _openIdExpires = DateTime(0);

  static Future<String> _openId(Client c) async {
    if (_openIdToken != null && DateTime.now().isBefore(_openIdExpires))
      return _openIdToken!;
    final cred = await c.requestOpenIdToken(c.userID!, {});
    _openIdToken = cred.accessToken;
    _openIdExpires = DateTime.now().add(
      Duration(seconds: (cred.expiresIn - 60).clamp(30, 3600)),
    );
    return _openIdToken!;
  }

  /// OpenID token for the gateway (`openid:<token>` auth), cached.
  static Future<String> openIdToken(Client c) => _openId(c);

  static String _trim(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  static Never _fail(http.Response r) {
    String msg;
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      msg = (j['error'] ?? j['errcode'] ?? r.body).toString();
    } catch (_) {
      msg = 'HTTP ${r.statusCode}';
    }
    throw PersonalBridgeException(msg, r.statusCode);
  }

  /// The user's own bridge status, or null if they have none.
  static Future<OwnBridgeStatus?> status(Client c, String gateway) async {
    final r = await http
        .get(
          Uri.parse('${_trim(gateway)}/provision/v1/bridge'),
          headers: {'Authorization': 'Bearer openid:${await _openId(c)}'},
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r);
    return OwnBridgeStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Removes the bridge on the server (instant, no restart needed).
  static Future<void> revoke(Client c, String gateway) async {
    final r = await http
        .delete(
          Uri.parse('${_trim(gateway)}/provision/v1/bridge'),
          headers: {'Authorization': 'Bearer openid:${await _openId(c)}'},
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200 && r.statusCode != 404) _fail(r);
  }

  /// A short-lived login token for the bridge app (MSC3882 / get_token).
  /// Returns null if the server has login-via-existing-session disabled.
  static Future<({String token, Duration expires})?> loginToken(
    Client c, {
    required String password,
  }) async {
    try {
      GenerateLoginTokenResponse resp;
      try {
        resp = await c.generateLoginToken();
      } on MatrixException catch (e) {
        if (e.session == null) rethrow;
        resp = await c.generateLoginToken(
          auth: AuthenticationPassword(
            session: e.session,
            password: password,
            identifier: AuthenticationUserIdentifier(user: c.userID!),
          ),
        );
      }
      return (
        token: resp.loginToken,
        expires: Duration(milliseconds: resp.expiresInMs),
      );
    } on MatrixException catch (e) {
      if (e.errcode == 'M_UNRECOGNIZED' ||
          e.errcode == 'M_FORBIDDEN' && e.errorMessage.contains('disabled')) {
        return null;
      }
      rethrow;
    }
  }

  static String pairingLink({
    required Client c,
    required String gateway,
    String? loginToken,
  }) {
    return Uri(
      scheme: 'tjena-bridge',
      host: 'login',
      queryParameters: {
        'hs': c.homeserver.toString().replaceAll(RegExp(r'/$'), ''),
        'gw': gateway,
        'user': ?c.userID,
        'token': ?loginToken,
      },
    ).toString();
  }

  /// A separate Matrix session used only by the bridge for double puppeting.
  /// The user can log it out any time (Settings → Devices).
  static Future<String> createDoublePuppetToken(
    Client c,
    String password,
  ) async {
    final r = await http
        .post(
          c.homeserver!.resolve('_matrix/client/v3/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'type': 'm.login.password',
            'identifier': {'type': 'm.id.user', 'user': c.userID},
            'password': password,
            'initial_device_display_name': doublePuppetDeviceName,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) _fail(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['access_token']
        as String;
  }
}

/// Talking to a bridge bot in its (encrypted) management DM.
class BridgeBotChat {
  static Room? existingDm(Client c, String bot) => c.rooms.firstWhereOrNull(
    (r) =>
        r.isDirectChat &&
        r.directChatMatrixID == bot &&
        r.membership == Membership.join,
  );

  static Future<Room> dm(Client c, String bot) async {
    final existing = existingDm(c, bot);
    if (existing != null) return existing;
    final id = await c.startDirectChat(bot, enableEncryption: true);
    await c.waitForRoomInSync(id, join: true);
    return c.getRoomById(id)!;
  }

  /// The bot's replies don't reference the command, so commands run one at
  /// a time: otherwise two commands could each take the other's reply.
  static Future<void> _queue = Future.value();

  /// Sends [command] and waits for the bot's next text reply.
  /// With [redactAfter] the command message is redacted once answered (used
  /// for `login-matrix <token>`, so the token doesn't stay in chat history).
  static Future<String?> command(
    Room room,
    String bot,
    String command, {
    Duration timeout = const Duration(seconds: 45),
    bool redactAfter = false,
    bool Function(String body)? accept,
  }) async => (await commandFull(
    room,
    bot,
    command,
    timeout: timeout,
    redactAfter: redactAfter,
    accept: accept,
  ))?.body;

  /// Like [command], with the reply's formatted_body too.
  ///
  /// The reply is the bot's first message after the command in the room.
  /// [accept] skips bot messages that can't be the answer (e.g. the late
  /// answer to an earlier command that timed out).
  static Future<({String? html, String? body})?> commandFull(
    Room room,
    String bot,
    String command, {
    Duration timeout = const Duration(seconds: 45),
    bool redactAfter = false,
    bool Function(String body)? accept,
  }) {
    final result = _queue.then(
      (_) => _run(room, bot, command, timeout, redactAfter, accept),
    );
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<({String? html, String? body})?> _run(
    Room room,
    String bot,
    String command,
    Duration timeout,
    bool redactAfter,
    bool Function(String body)? accept,
  ) async {
    final c = room.client;
    final completer = Completer<({String? html, String? body})?>();
    // Events of this room in arrival order; the answer is the first fitting
    // bot message after the command itself.
    final seen = <Event>[];
    String? sentId;
    var sentAt = 0; // seen.length when the send returned
    void check() {
      if (sentId == null || completer.isCompleted) return;
      final own = seen.indexWhere((e) => e.eventId == sentId);
      final start = own >= 0 ? own + 1 : sentAt;
      for (final e in seen.skip(start)) {
        if (e.senderId != bot || e.type != EventTypes.Message) continue;
        if (accept != null && !accept(e.body)) continue;
        completer.complete((
          html: e.content['formatted_body'] as String?,
          body: e.body,
        ));
        return;
      }
    }

    final sub = c.onTimelineEvent.stream.listen((e) {
      if (e.roomId != room.id) return;
      seen.add(e);
      check();
    });
    try {
      sentId = await room.sendTextEvent(command);
      // Not sent (e.g. tjena refused it for sending too fast): no answer.
      if (sentId == null) return null;
      sentAt = seen.length;
      check();
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
      if (redactAfter && sentId != null) {
        try {
          await room.redactEvent(sentId, reason: 'Contained a login token');
        } catch (e) {
          Logs().w('[PersonalBridge] could not redact command', e);
        }
      }
    }
  }

  /// The bot's possible answers to `search`, `start-chat` and `list-logins`.
  static bool isSearchReply(String b) =>
      b.startsWith('Search results') ||
      b.startsWith('Failed to search') ||
      _isGenericReply(b);
  static bool isStartChatReply(String b) =>
      b.startsWith('Created chat with') ||
      b.startsWith('You already have a direct chat') ||
      b.startsWith('Failed to resolve') ||
      b.startsWith('Identifier ') ||
      _isGenericReply(b);
  static bool isListLoginsReply(String b) =>
      RegExp(r'^\s*\* `[^`]+` \(', multiLine: true).hasMatch(b) ||
      _isGenericReply(b);
  static bool _isGenericReply(String b) =>
      b.startsWith("You're not logged in") ||
      b.startsWith('This bridge does not support') ||
      b.startsWith('Usage:') ||
      b.startsWith('Unknown command');

  /// Logins from bridgev2's `list-logins` reply,
  /// e.g. "* `491701234567` (+49 170 1234567) - `CONNECTED`".
  static List<({String id, String name, String state})> parseLogins(
    String? text,
  ) {
    if (text == null) return [];
    final out = <({String id, String name, String state})>[];
    for (final line in text.split('\n')) {
      final ticks = RegExp(
        r'`([^`]+)`',
      ).allMatches(line).map((m) => m.group(1)!).toList();
      if (!RegExp(r'^\s*[*-]').hasMatch(line) || ticks.isEmpty) continue;
      final name = RegExp(r'`\s*\((.*)\)\s*-\s*`').firstMatch(line)?.group(1);
      out.add((
        id: ticks.first,
        name: name?.trim() ?? '',
        state: ticks.length > 1 ? ticks.last : '',
      ));
    }
    return out;
  }

  /// Logs every WhatsApp login out of [bot]. Returns how many were logged out.
  static Future<int> logoutAll(Client c, String bot) async {
    final room = await dm(c, bot);
    final logins = parseLogins(
      await command(room, bot, 'list-logins', accept: isListLoginsReply),
    );
    for (final l in logins) {
      await command(room, bot, 'logout ${l.id}');
    }
    return logins.length;
  }
}

/// The WhatsApp accounts (bridgev2 logins) behind bridged chats. A portal
/// belongs to one login: m.bridge channel["fi.mau.receiver"] (or
/// channel.receiver). Groups can be shared by several logins and then have none.
class WaAccounts {
  /// login ID → name from `list-logins` (e.g. "+49 170 1234567").
  static final Map<String, String> _names = {};

  /// The login a portal belongs to, from its m.bridge state. DMs have one;
  /// groups usually don't (several logins can share a group).
  static String? receiverOf(Room room) {
    final channel = _channel(room);
    if (channel == null) return null;
    for (final key in const ['fi.mau.receiver', 'receiver']) {
      final r = channel[key];
      if (r is String && r.isNotEmpty) return r;
    }
    return null;
  }

  static Map? _channel(Room room) {
    for (final type in const ['m.bridge', 'uk.half-shot.bridge']) {
      final states = room.states[type];
      if (states == null || states.isEmpty) continue;
      final channel = states.values.first.content['channel'];
      if (channel is Map) return channel;
    }
    return null;
  }

  /// bridgev2 gives every login its own space ("WhatsApp (+49…)") holding
  /// all of that account's chats, groups included.
  static bool isAccountSpace(Room r) =>
      r.isSpace && _channel(r)?['id'] == '__personal_filtering_space__';

  static Map<String, Set<String>> _index = {};
  static DateTime _indexAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// room id → accounts whose space contains it (rebuilt at most every 2 s).
  static Map<String, Set<String>> _spaceIndex(Client c) {
    if (DateTime.now().difference(_indexAt) < const Duration(seconds: 2)) {
      return _index;
    }
    final index = <String, Set<String>>{};
    for (final space in c.rooms) {
      if (!isAccountSpace(space)) continue;
      final acct = receiverOf(space);
      if (acct == null) continue;
      for (final child in space.spaceChildren) {
        final id = child.roomId;
        if (id != null) (index[id] ??= {}).add(acct);
      }
    }
    _indexAt = DateTime.now();
    return _index = index;
  }

  /// All own accounts a chat belongs to (a group can be in several).
  static Set<String> accountsOf(Room room) {
    final r = receiverOf(room);
    if (r != null) return {r};
    return _spaceIndex(room.client)[room.id] ?? const {};
  }

  /// The account of a chat, if it is exactly one.
  static String? of(Room room) {
    final a = accountsOf(room);
    return a.length == 1 ? a.first : null;
  }

  static Future<void>? _loading;

  /// m.bridge isn't loaded with the room list: loads the full state of every
  /// joined room once (in the background) so [of] works for all chats.
  static Future<void> ensureLoaded(Client c) => _loading ??= () async {
    for (final r in c.rooms.toList()) {
      if (!r.partial || r.membership != Membership.join) continue;
      try {
        await r.postLoad();
      } catch (e) {
        Logs().w('[WaAccounts] postLoad ${r.id}', e);
      }
    }
    _indexAt = DateTime.fromMillisecondsSinceEpoch(0);
  }();

  /// Accounts seen in the user's chats (of [bot] only, if given).
  static Set<String> known(Client c, {String? bot}) => {
    for (final r in c.rooms)
      if (bot == null || RoomBridgeInfo.of(r)?.bridgeBot == bot) ?receiverOf(r),
  };

  /// "+49 170 1234567" for a login ID (phone digits), or the name the
  /// bridge gave it.
  static String label(String id) {
    final name = _names[id];
    if (name != null && name.isNotEmpty && name != id) return name;
    return RegExp(r'^\d+$').hasMatch(id) ? '+$id' : id;
  }

  /// Asks [bot] for the logins (and remembers their names for [label]).
  static Future<List<({String id, String name, String state})>> fetch(
    Client c,
    String bot,
  ) async {
    final room = await BridgeBotChat.dm(c, bot);
    final logins = BridgeBotChat.parseLogins(
      await BridgeBotChat.command(
        room,
        bot,
        'list-logins',
        accept: BridgeBotChat.isListLoginsReply,
      ),
    );
    for (final l in logins) {
      _names[l.id] = l.name;
    }
    return logins;
  }
}

/// Which bridge serves a room, from its m.bridge / uk.half-shot.bridge state.
class RoomBridgeInfo {
  final String bridgeBot;
  final String? protocol;
  RoomBridgeInfo(this.bridgeBot, this.protocol);

  static RoomBridgeInfo? of(Room room) {
    for (final type in const ['m.bridge', 'uk.half-shot.bridge']) {
      final states = room.states[type];
      if (states == null || states.isEmpty) continue;
      final content = states.values.first.content;
      final bot = content['bridgebot'] as String?;
      if (bot == null) continue;
      final protocol =
          (content['protocol'] as Map?)?['displayname'] as String? ??
          (content['protocol'] as Map?)?['id'] as String?;
      return RoomBridgeInfo(bot, protocol);
    }
    return null;
  }

  bool isOwnBridge(Client c) => WhatsAppBridgeConfig.of(c).ownBot == bridgeBot;

  String describe(Client c) {
    final cfg = WhatsAppBridgeConfig.of(c);
    final name = protocol ?? 'Bridge';
    if (cfg.ownBot == bridgeBot) return '$name · your own bridge (home)';
    if (bridgeBot == WhatsAppBridgeConfig.serverBot(c))
      return '$name · tjena server bridge';
    return '$name · $bridgeBot';
  }
}

/// Watches the own bridge while the app runs and notifies when it has been
/// offline longer than the configured threshold.
class PersonalBridgeMonitor {
  static PersonalBridgeMonitor? _instance;
  final Client client;
  final status = ValueNotifier<OwnBridgeStatus?>(null);
  Timer? _timer;
  // Cancelled when the monitor is replaced (start with another client).
  // ignore: cancel_subscriptions
  StreamSubscription<SyncUpdate>? _syncSub;
  bool _notifiedThisOutage = false;

  /// Reasons the bridges use when they remove you from a chat they delete
  /// (e.g. after you log a WhatsApp account out).
  static const _portalDeletedReasons = {
    'Deleting portal',
    'Logged out of bridge',
  };

  /// When a WhatsApp bridge deletes a chat or space (logout cleanup), forget
  /// it so it doesn't linger in the archive.
  Future<void> _forgetDeletedPortals(SyncUpdate sync) async {
    final left = sync.rooms?.leave;
    if (left == null || left.isEmpty) return;
    final bots = {
      WhatsAppBridgeConfig.serverBot(client),
      ?WhatsAppBridgeConfig.of(client).ownBot,
    };
    for (final entry in left.entries) {
      final events = [...?entry.value.state, ...?entry.value.timeline?.events];
      final removed = events.any(
        (e) =>
            e.type == EventTypes.RoomMember &&
            e.stateKey == client.userID &&
            bots.contains(e.senderId) &&
            e.content['membership'] == 'leave' &&
            _portalDeletedReasons.contains(e.content['reason']),
      );
      if (!removed) continue;
      try {
        await client.forgetRoom(entry.key);
        await client.database.forgetRoom(entry.key);
        Logs().i(
          '[PersonalBridge] forgot chat ${entry.key} deleted by the bridge',
        );
      } catch (e) {
        Logs().w('[PersonalBridge] could not forget ${entry.key}', e);
      }
    }
  }

  PersonalBridgeMonitor._(this.client);

  final _joining = <String>{};
  bool _acceptRunning = false;

  /// Linking WhatsApp makes the bridge invite you to every chat (also with
  /// double puppeting, where invites can arrive before the bridge has the
  /// puppet token). Invites from the user's own WhatsApp bridges (server
  /// bridge and own bridge, bot or WhatsApp contacts) are accepted here.
  Future<void> _acceptBridgeInvites() async {
    if (_acceptRunning) return;
    _acceptRunning = true;
    try {
      while (true) {
        final cfg = WhatsAppBridgeConfig.of(client);
        // Only the bridge in use: chats of a bridge you left (e.g. the old
        // server bridge) must not be accepted again.
        final bots = [cfg.activeBot(client)];
        final next = client.rooms.firstWhereOrNull((r) {
          if (r.membership != Membership.invite || _joining.contains(r.id)) {
            return false;
          }
          final inviter = r
              .getState(EventTypes.RoomMember, client.userID!)
              ?.senderId;
          return bots.any((b) => BridgeCleanup.isFromBridge(inviter, b));
        });
        if (next == null) break;
        _joining.add(next.id);
        try {
          await next.join();
          Logs().i('[PersonalBridge] accepted bridge invite ${next.id}');
        } on MatrixException catch (e) {
          if (e.error == MatrixError.M_LIMIT_EXCEEDED) {
            // tjena limits how fast you join rooms: wait as long as it asks
            // and try the same invite again.
            _joining.remove(next.id);
            final wait = e.retryAfterMs ?? 10000;
            Logs().i('[PersonalBridge] join rate limited, waiting ${wait}ms');
            await Future.delayed(Duration(milliseconds: wait + 200));
            continue;
          }
          Logs().w('[PersonalBridge] could not accept ${next.id}', e);
        } catch (e) {
          Logs().w('[PersonalBridge] could not accept ${next.id}', e);
        }
        // Many chats arrive at once after linking: don't hit rate limits.
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _acceptRunning = false;
    }
  }

  static PersonalBridgeMonitor start(Client client) {
    if (_instance?.client == client) return _instance!;
    _instance?._timer?.cancel();
    _instance?._syncSub?.cancel();
    final m = PersonalBridgeMonitor._(client);
    m._syncSub = client.onSync.stream.listen((sync) {
      m._forgetDeletedPortals(sync);
      if (sync.rooms?.invite?.isNotEmpty ?? false) m._acceptBridgeInvites();
    });
    // Invites that arrived while the app was closed.
    client.roomsLoading?.then((_) => m._acceptBridgeInvites());
    m._timer = Timer.periodic(const Duration(minutes: 5), (_) => m.check());
    Future.delayed(const Duration(seconds: 30), m.check);
    _instance = m;
    return m;
  }

  static PersonalBridgeMonitor? get instance => _instance;

  Future<void> check() async {
    final cfg = WhatsAppBridgeConfig.of(client);
    if (!cfg.usesOwn) {
      status.value = null;
      return;
    }
    try {
      final st = await PersonalBridgeApi.status(client, cfg.gateway);
      status.value = st;
      if (st == null) return;
      final off = st.offlineFor;
      if (off == null) {
        _notifiedThisOutage = false;
      } else if (off.inMinutes >= cfg.offlineNotifyMinutes &&
          !_notifiedThisOutage) {
        _notifiedThisOutage = true;
        await _notify(off);
      }
    } catch (e) {
      Logs().d('[PersonalBridge] status check failed: $e');
    }
  }

  Future<void> _notify(Duration off) async {
    if (kIsWeb) return;
    final plugin = FlutterLocalNotificationsPlugin();
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'own_bridge_status',
        'WhatsApp bridge status',
        importance: Importance.defaultImportance,
      ),
    );
    final hours = off.inHours;
    final since = hours > 0 ? '$hours h' : '${off.inMinutes} min';
    await plugin.show(
      id: 'own_bridge_offline'.hashCode,
      title: 'Your WhatsApp bridge is offline',
      body:
          'The bridge at home has been offline for $since. Messages you send are delivered when it is back. '
          'Check that the bridge phone has power and Wi-Fi.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'own_bridge_status',
          'WhatsApp bridge status',
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}

/// Removes a WhatsApp bridge from the account after it broke off badly
/// (e.g. the bridge phone was reset): logs out what still answers, removes
/// the own bridge from the tjena server, and leaves + forgets its chats,
/// spaces, invites and the bot chat. Every step is best effort.
class BridgeCleanup {
  /// Ghost users of a bridge are `X_…` for the bot `Xbot`.
  static String? _ghostPrefix(String bot) {
    final local = bot.startsWith('@') ? bot.substring(1).split(':').first : '';
    if (!local.endsWith('bot') || local.length <= 3) return null;
    return '${local.substring(0, local.length - 3)}_';
  }

  static bool isFromBridge(String? userId, String bot) {
    if (userId == null) return false;
    if (userId == bot) return true;
    final prefix = _ghostPrefix(bot);
    if (prefix == null) return false;
    return userId.startsWith('@$prefix') &&
        userId.split(':').skip(1).join(':') == bot.split(':').skip(1).join(':');
  }

  /// Chats, spaces and invites of the bridge with the bot [bot].
  static List<Room> roomsOf(Client c, String bot) => c.rooms.where((r) {
    if (r.membership == Membership.leave) return false;
    if (RoomBridgeInfo.of(r)?.bridgeBot == bot) return true;
    if (r.directChatMatrixID == bot) return true;
    if (isFromBridge(r.getState(EventTypes.RoomCreate)?.senderId, bot)) {
      return true;
    }
    if (r.membership == Membership.invite) {
      final me = r.getState(EventTypes.RoomMember, c.userID!);
      if (isFromBridge(me?.senderId, bot)) return true;
    }
    return false;
  }).toList();

  /// Runs the cleanup. [own]: the bridge is the user's own bridge (also
  /// removed on the tjena server and switched back to the server bridge).
  static Future<void> run(
    Client c, {
    required String bot,
    required bool own,
    bool logout = true,
    required void Function(String line) log,
  }) async {
    if (logout) {
      log('Logging WhatsApp out of $bot…');
      try {
        final n = await BridgeBotChat.logoutAll(
          c,
          bot,
        ).timeout(const Duration(seconds: 60));
        log(n == 0 ? 'No login answered (bridge offline?).' : 'Logged out $n.');
      } catch (e) {
        log('Logout skipped: $e');
      }
    }
    if (own) {
      final cfg = WhatsAppBridgeConfig.of(c);
      log('Removing your own bridge from the tjena server…');
      try {
        await PersonalBridgeApi.revoke(c, cfg.gateway);
        log('Removed on the server.');
      } catch (e) {
        log('Server removal failed: $e');
      }
      try {
        await cfg.copyWith(mode: 'server', clearOwn: true).save(c);
        log('Switched back to the tjena server bridge.');
      } catch (e) {
        log('Could not reset the bridge setting: $e');
      }
    }
    log('Loading chat details…');
    await WaAccounts.ensureLoaded(c);
    final rooms = roomsOf(c, bot);
    log('Removing ${rooms.length} chats, spaces and invites…');
    var failed = 0;
    for (final r in rooms) {
      try {
        if (r.membership != Membership.leave) await r.leave();
      } catch (_) {}
      try {
        await r.forget();
      } catch (_) {
        failed++;
      }
    }
    log(
      failed == 0
          ? 'Done.'
          : 'Done; $failed could not be forgotten (they stay in the archive).',
    );
  }
}
