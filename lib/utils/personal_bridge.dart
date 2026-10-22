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

  static String serverBot(Client c) => '@whatsappbot:${c.userID?.domain ?? 'tjena.eu'}';

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
  }) =>
      WhatsAppBridgeConfig(
        mode: mode ?? this.mode,
        ownBot: clearOwn ? null : ownBot ?? this.ownBot,
        slot: clearOwn ? null : slot ?? this.slot,
        gateway: gateway ?? this.gateway,
        offlineNotifyMinutes: offlineNotifyMinutes ?? this.offlineNotifyMinutes,
      );

  Future<void> save(Client c) => c.setAccountData(c.userID!, whatsAppBridgeAccountDataType, {
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
  Duration? get offlineFor => connected || lastSeen == null ? null : DateTime.now().difference(lastSeen!.toLocal());
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
    if (_openIdToken != null && DateTime.now().isBefore(_openIdExpires)) return _openIdToken!;
    final cred = await c.requestOpenIdToken(c.userID!, {});
    _openIdToken = cred.accessToken;
    _openIdExpires = DateTime.now().add(Duration(seconds: (cred.expiresIn - 60).clamp(30, 3600)));
    return _openIdToken!;
  }

  static String _trim(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

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
    final r = await http.get(
      Uri.parse('${_trim(gateway)}/provision/v1/bridge'),
      headers: {'Authorization': 'Bearer openid:${await _openId(c)}'},
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r);
    return OwnBridgeStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Removes the bridge on the server (instant, no restart needed).
  static Future<void> revoke(Client c, String gateway) async {
    final r = await http.delete(
      Uri.parse('${_trim(gateway)}/provision/v1/bridge'),
      headers: {'Authorization': 'Bearer openid:${await _openId(c)}'},
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200 && r.statusCode != 404) _fail(r);
  }

  /// A short-lived login token for the bridge app (MSC3882 / get_token).
  /// Returns null if the server has login-via-existing-session disabled.
  static Future<({String token, Duration expires})?> loginToken(Client c, {required String password}) async {
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
      return (token: resp.loginToken, expires: Duration(milliseconds: resp.expiresInMs));
    } on MatrixException catch (e) {
      if (e.errcode == 'M_UNRECOGNIZED' || e.errcode == 'M_FORBIDDEN' && e.errorMessage.contains('disabled')) {
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
  static Future<String> createDoublePuppetToken(Client c, String password) async {
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
    return (jsonDecode(r.body) as Map<String, dynamic>)['access_token'] as String;
  }
}

/// Talking to a bridge bot in its (encrypted) management DM.
class BridgeBotChat {
  static Room? existingDm(Client c, String bot) =>
      c.rooms.firstWhereOrNull((r) => r.isDirectChat && r.directChatMatrixID == bot && r.membership == Membership.join);

  static Future<Room> dm(Client c, String bot) async {
    final existing = existingDm(c, bot);
    if (existing != null) return existing;
    final id = await c.startDirectChat(bot, enableEncryption: true);
    await c.waitForRoomInSync(id, join: true);
    return c.getRoomById(id)!;
  }

  /// Sends [command] and waits for the bot's next text reply.
  /// With [redactAfter] the command message is redacted once answered (used
  /// for `login-matrix <token>`, so the token doesn't stay in chat history).
  static Future<String?> command(
    Room room,
    String bot,
    String command, {
    Duration timeout = const Duration(seconds: 45),
    bool redactAfter = false,
  }) async {
    final c = room.client;
    final sentAfter = DateTime.now().subtract(const Duration(seconds: 1));
    final completer = Completer<String?>();
    late final StreamSubscription sub;
    sub = c.onTimelineEvent.stream.listen((e) {
      if (e.roomId != room.id || e.senderId != bot) return;
      if (e.originServerTs.isBefore(sentAfter)) return;
      if (e.type != EventTypes.Message) return;
      if (!completer.isCompleted) completer.complete(e.body);
    });
    String? sentId;
    try {
      sentId = await room.sendTextEvent(command);
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

  /// IDs from bridgev2's `list-logins` reply, e.g. "* `491701234567` (…) - `CONNECTED`".
  static List<({String id, String state})> parseLogins(String? text) {
    if (text == null) return [];
    final out = <({String id, String state})>[];
    for (final line in text.split('\n')) {
      final ticks = RegExp(r'`([^`]+)`').allMatches(line).map((m) => m.group(1)!).toList();
      if (!RegExp(r'^\s*[*-]').hasMatch(line) || ticks.isEmpty) continue;
      out.add((id: ticks.first, state: ticks.length > 1 ? ticks.last : ''));
    }
    return out;
  }

  /// Logs every WhatsApp login out of [bot]. Returns how many were logged out.
  static Future<int> logoutAll(Client c, String bot) async {
    final room = await dm(c, bot);
    final logins = parseLogins(await command(room, bot, 'list-logins'));
    for (final l in logins) {
      await command(room, bot, 'logout ${l.id}');
    }
    return logins.length;
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
      final protocol = (content['protocol'] as Map?)?['displayname'] as String? ?? (content['protocol'] as Map?)?['id'] as String?;
      return RoomBridgeInfo(bot, protocol);
    }
    return null;
  }

  bool isOwnBridge(Client c) => WhatsAppBridgeConfig.of(c).ownBot == bridgeBot;

  String describe(Client c) {
    final cfg = WhatsAppBridgeConfig.of(c);
    final name = protocol ?? 'Bridge';
    if (cfg.ownBot == bridgeBot) return '$name · your own bridge (home)';
    if (bridgeBot == WhatsAppBridgeConfig.serverBot(c)) return '$name · tjena server bridge';
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
  bool _notifiedThisOutage = false;

  PersonalBridgeMonitor._(this.client);

  static PersonalBridgeMonitor start(Client client) {
    if (_instance?.client == client) return _instance!;
    _instance?._timer?.cancel();
    final m = PersonalBridgeMonitor._(client);
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
      } else if (off.inMinutes >= cfg.offlineNotifyMinutes && !_notifiedThisOutage) {
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
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel('own_bridge_status', 'WhatsApp bridge status', importance: Importance.defaultImportance),
    );
    final hours = off.inHours;
    final since = hours > 0 ? '$hours h' : '${off.inMinutes} min';
    await plugin.show(
      id: 'own_bridge_offline'.hashCode,
      title: 'Your WhatsApp bridge is offline',
      body: 'The bridge at home has been offline for $since. Messages you send are delivered when it is back. '
          'Check that the bridge phone has power and Wi-Fi.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('own_bridge_status', 'WhatsApp bridge status'),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}
