// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:fluffychat/utils/platform_infos.dart';
import 'package:matrix/matrix.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

/// Keeps the on-device WhatsApp/Signal bridge alive in the background via an
/// Android foreground service, so messages (which arrive peer-to-peer, not via
/// the homeserver) are received and can notify even when the app is closed.
///
/// Without this the OS kills the app process when backgrounded and the bridge
/// connection dies, so WhatsApp messages only appeared after reopening the app.
class BridgeKeepAlive {
  BridgeKeepAlive._();

  static bool _running = false;
  static bool _initialized = false;

  /// Start the service if any local-bridge account is linked, otherwise stop it.
  /// Idempotent — safe to call on app start and on every bridge state change.
  static Future<void> refresh() async {
    if (!PlatformInfos.isAndroid) return;
    var anyLinked = false;
    try {
      final accounts = await TjenaBridge.instance.listAccounts();
      anyLinked = accounts.any((a) => a['linked'] == true);
    } catch (_) {
      return;
    }
    if (anyLinked) {
      await start();
    } else {
      await _stop();
    }
  }

  /// Force-start the service (used during pairing, before an account is linked).
  static Future<void> start() async {
    if (_running) return;
    try {
      if (!_initialized) {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'tjena_bridge_keepalive',
            channelName: 'Bridge connection',
            channelDescription:
                'Keeps WhatsApp/Signal connected so you receive messages.',
          ),
          iosNotificationOptions: const IOSNotificationOptions(),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.nothing(),
          ),
        );
        _initialized = true;
      }
      await FlutterForegroundTask.startService(
        notificationTitle: 'Tjena',
        notificationText: 'Connected — receiving messages',
      );
      _running = true;
    } catch (e) {
      Logs().w('[BridgeKeepAlive] start failed: $e');
    }
  }

  static Future<void> _stop() async {
    if (!_running) return;
    _running = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
