import 'dart:convert';

import 'package:flutter/services.dart';

/// Thin wrapper around the Kotlin side (BridgeService, SecretStore, relay).
class Native {
  static const _ch = MethodChannel('eu.tjena.bridge/native');

  static Future<BridgeState> state() async =>
      BridgeState(jsonDecode(await _ch.invokeMethod<String>('getState') ?? '{}'));

  static Future<Map<String, dynamic>?> session() async {
    final s = await _ch.invokeMethod<String>('getSession');
    return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
  }

  static Future<void> saveSetup({
    required Map<String, dynamic> bundle,
    required Map<String, dynamic> session,
    required String gateway,
  }) =>
      _ch.invokeMethod('saveSetup', {
        'bundle': jsonEncode(bundle),
        'session': jsonEncode(session),
        'gateway': gateway,
      });

  static Future<void> updateBundle(Map<String, dynamic> bundle) =>
      _ch.invokeMethod('updateBundle', {'bundle': jsonEncode(bundle)});

  static Future<void> start() => _ch.invokeMethod('start');
  static Future<void> stop() => _ch.invokeMethod('stop');
  static Future<void> restart() => _ch.invokeMethod('restart');

  /// Calls the bridge's provisioning API through the local relay.
  static Future<RelayResponse> relay(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final raw = await _ch.invokeMethod<String>('relay', {
      'method': method,
      'path': path,
      'body': body == null ? null : jsonEncode(body),
      'timeoutMs': timeout.inMilliseconds,
    });
    final m = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
    return RelayResponse(m['status'] as int? ?? 0, m['body'] as String? ?? '');
  }

  /// Calls the WhatsApp calls daemon's local API.
  static Future<RelayResponse> wacall(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final raw = await _ch.invokeMethod<String>('wacall', {
      'method': method,
      'path': path,
      'body': body == null ? null : jsonEncode(body),
      'timeoutMs': timeout.inMilliseconds,
    });
    final m = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
    return RelayResponse(m['status'] as int? ?? 0, m['body'] as String? ?? '');
  }

  static Future<void> setCallsEnabled(bool on) => _ch.invokeMethod('setCallsEnabled', {'on': on});

  static Future<void> setExtraUsers(List<String> users) =>
      _ch.invokeMethod('setExtraUsers', {'users': users});

  static Future<void> setGatewayUrl(String url) => _ch.invokeMethod('setGatewayUrl', {'url': url});

  static Future<Map<String, dynamic>> options() async =>
      jsonDecode(await _ch.invokeMethod<String>('getOptions') ?? '{}') as Map<String, dynamic>;

  /// Saves bridge options and restarts the bridge if it runs.
  static Future<void> setOptions(Map<String, dynamic> options) =>
      _ch.invokeMethod('setOptions', {'options': jsonEncode(options)});

  /// Keys and trust as stored in the bridge's own database (read-only).
  static Future<Map<String, dynamic>> securityInfo() async =>
      jsonDecode(await _ch.invokeMethod<String>('securityInfo') ?? '{}') as Map<String, dynamic>;

  /// History import progress and problems (read-only).
  static Future<Map<String, dynamic>> historyInfo() async =>
      jsonDecode(await _ch.invokeMethod<String>('historyInfo') ?? '{}') as Map<String, dynamic>;

  /// Stops the bridge, marks chats whose history import stopped early, and
  /// starts it again so it copies the rest. Returns {chats, stored}.
  /// Fast history import: 'pause' / 'resume' double puppeting (restarts the
  /// bridge) or 'status' ({paused, import_done, pending, ...}).
  static Future<Map<String, dynamic>> doublePuppet(String action) async =>
      jsonDecode(await _ch.invokeMethod<String>('doublePuppet', {'action': action}) ?? '{}') as Map<String, dynamic>;

  static Future<Map<String, dynamic>> historyCatchup() async =>
      jsonDecode(await _ch.invokeMethod<String>('historyCatchup') ?? '{}') as Map<String, dynamic>;

  static Future<void> setNotificationPrefs({required String style, required bool alerts}) =>
      _ch.invokeMethod('setNotificationPrefs', {'style': style, 'alerts': alerts});

  /// Opens Android's settings for one notification channel (or the whole app).
  static Future<void> openNotificationSettings([String? channel]) =>
      _ch.invokeMethod('openNotificationSettings', {'channel': channel});

  static Future<void> requestBatteryExemption() => _ch.invokeMethod('requestBatteryExemption');

  static Future<String> recentLog() async => await _ch.invokeMethod<String>('recentLog') ?? '';

  static Future<String> exportLogs() async => await _ch.invokeMethod<String>('exportLogs') ?? '';

  static Future<bool> exportBackup(String passphrase) async =>
      await _ch.invokeMethod<bool>('exportBackup', {'passphrase': passphrase}) ?? false;

  static Future<bool> importBackup(String passphrase) async =>
      await _ch.invokeMethod<bool>('importBackup', {'passphrase': passphrase}) ?? false;

  static Future<void> wipe() => _ch.invokeMethod('wipe');
}

class RelayResponse {
  final int status;
  final String body;
  RelayResponse(this.status, this.body);

  bool get ok => status >= 200 && status < 300;

  Map<String, dynamic> get json {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : {'value': v};
    } catch (_) {
      return {'error': body};
    }
  }

  String get errorMessage {
    final j = json;
    return (j['error'] ?? j['errcode'] ?? 'Error $status').toString();
  }
}

class BridgeState {
  final Map<String, dynamic> raw;
  BridgeState(this.raw);

  bool get setUp => raw['set_up'] == true;
  bool get enabled => raw['enabled'] == true;
  bool get callsEnabled => raw['calls_enabled'] == true;
  String get serviceState => raw['service_state'] as String? ?? 'stopped';
  String? get serviceDetail => raw['service_detail'] as String?;
  String? get lastExit => raw['last_exit'] as String?;
  bool get batteryUnrestricted => raw['battery_unrestricted'] == true;
  bool get binariesPresent => raw['binaries_present'] == true;
  String get bridgeVersion => raw['bridge_version'] as String? ?? '?';
  String get appVersion => raw['app_version'] as String? ?? '?';
  String get owner => raw['owner'] as String? ?? '';
  String get slot => raw['slot'] as String? ?? '';
  String get botMxid => raw['bot_mxid'] as String? ?? '';
  String get gatewayUrl => raw['gateway_url'] as String? ?? 'https://wap.tjena.eu';
  String? get homeserver => raw['homeserver'] as String?;
  List<String> get extraUsers => (raw['extra_users'] as List?)?.cast<String>() ?? [];
  String get notifStyle => raw['notif_style'] as String? ?? 'normal';
  bool get notifAlerts => raw['notif_alerts'] != false;

  Map<String, dynamic> get relay => (raw['relay'] as Map?)?.cast<String, dynamic>() ?? {};
  bool get bridgeConnected => relay['bridge_connected'] == true;
  bool get upstreamConnected => relay['upstream_connected'] == true;
  bool get revoked => relay['revoked'] == true;
  String? get upstreamError => relay['upstream_error'] as String?;
  DateTime? get lastEvent => DateTime.tryParse(relay['last_event'] as String? ?? '');
  /// Send pacing in the relay: rate_limit_hits, rate_limit_retried,
  /// rate_limit_handed_back, sends_waiting, last_rate_limit.
  Map<String, dynamic> get pace => (relay['pace'] as Map?)?.cast<String, dynamic>() ?? {};
}
