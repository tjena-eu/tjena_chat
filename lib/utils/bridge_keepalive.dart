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
///
/// The service is *required* to show a persistent notification — that is the
/// deal Android makes for letting the process live. If the notification is not
/// visible, the service is not running.
///
/// **On dismissal:** the notification is posted as an ongoing notification, but
/// since Android 13 the system lets users swipe foreground-service
/// notifications away regardless — there is no flag that prevents it for a
/// dataSync service. What we can do is put it straight back:
///  * Android 14+ delivers an `onNotificationDismissed` callback to the task
///    handler ([_BridgeTaskHandler]), which immediately re-posts it.
///  * Android 13 gives no callback, so [reassertNotification] re-posts it
///    whenever the app is resumed.
/// Either way the service itself keeps running; only the notification goes
/// missing, and only until one of those fires.
/// Entry point for the foreground service's task isolate.
///
/// MUST be a top-level function annotated `vm:entry-point` — Android looks it
/// up by handle after a cold restart, and tree-shaking would otherwise drop it
/// from a release build. It deliberately does nothing but install the handler:
/// this isolate is not the app, and none of the app's state exists in it.
@pragma('vm:entry-point')
void bridgeKeepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_BridgeTaskHandler());
}

class _BridgeTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  /// Never fires — the service is configured with
  /// `ForegroundTaskEventAction.nothing()`, so this isolate stays idle instead
  /// of waking the CPU on a timer.
  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  /// Android 14+ only. The service is still alive at this point — only its
  /// notification is gone — so put it straight back.
  ///
  /// `updateService` re-issues `NotificationManager.notify()` with the
  /// service's id, which re-shows it. Deliberately not `restartService`: that
  /// would tear down and recreate this very isolate from inside itself, and
  /// the notification is the only thing that needs fixing. Passing no content
  /// keeps whatever title/text was last set.
  @override
  void onNotificationDismissed() {
    // ignore: unawaited_futures
    FlutterForegroundTask.updateService();
  }
}

class BridgeKeepAlive {
  BridgeKeepAlive._();

  static bool _initialized = false;
  static String? _lastText;

  /// Last failure reason, surfaced in the bridge settings screen so a silently
  /// missing notification is diagnosable instead of invisible.
  static String? lastError;

  /// Whether the OS reports the service as running right now. This is the only
  /// trustworthy source: a Dart-side flag goes stale whenever the process is
  /// killed and restarted while the service itself survives.
  static Future<bool> get isRunning async {
    if (!PlatformInfos.isAndroid) return false;
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  /// Ask for POST_NOTIFICATIONS (Android 13+). Without it Android starts the
  /// service but suppresses its notification, which looks exactly like the
  /// service never starting. Returns true when notifications are allowed.
  ///
  /// Must be called while the app is in the foreground — Android ignores a
  /// permission request from the background.
  static Future<bool> ensureNotificationPermission() async {
    if (!PlatformInfos.isAndroid) return true;
    try {
      var permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        permission = await FlutterForegroundTask.requestNotificationPermission();
      }
      if (permission != NotificationPermission.granted) {
        lastError =
            'Notification permission $permission — Android hides the bridge '
            'notification, so the background connection cannot be kept alive.';
        Logs().w('[BridgeKeepAlive] $lastError');
        return false;
      }
      return true;
    } catch (e) {
      Logs().w('[BridgeKeepAlive] notification permission check failed: $e');
      return false;
    }
  }

  /// Start the service if any local-bridge account is linked, otherwise stop it.
  /// Idempotent — safe to call on app start and on every bridge state change.
  static Future<void> refresh() async {
    if (!PlatformInfos.isAndroid) return;
    var anyLinked = false;
    var anyConnected = false;
    try {
      final accounts = await TjenaBridge.instance.listAccounts();
      anyLinked = accounts.any((a) => a['linked'] == true);
      for (final a in accounts) {
        if (a['linked'] != true) continue;
        final st = await TjenaBridge.instance.getState(
          accountID: a['id'] as String? ?? 'default',
        );
        if (st.connected) anyConnected = true;
      }
    } catch (e) {
      Logs().w('[BridgeKeepAlive] listAccounts failed: $e');
      return;
    }
    if (!anyLinked) {
      await _stop();
      return;
    }
    await start();
    // Surface the real link state in the persistent notification — it is the
    // only place the user can see the bridge is alive while the app is closed.
    await _setText(
      anyConnected ? 'Connected — receiving messages' : 'Reconnecting…',
    );
  }

  /// Force-start the service (used during pairing, before an account is linked).
  static Future<void> start() async {
    if (!PlatformInfos.isAndroid) return;
    if (await isRunning) return;

    // Android 13+ suppresses the notification without this, and a foreground
    // service with a suppressed notification is killed like a background one.
    await ensureNotificationPermission();

    try {
      if (!_initialized) {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'tjena_bridge_keepalive',
            channelName: 'Bridge connection',
            channelDescription:
                'Keeps WhatsApp/Signal connected so you receive messages.',
            // LOW keeps it silent but still listed in the shade — the point is
            // that it is visible, not that it interrupts.
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
            onlyAlertOnce: true,
            visibility: NotificationVisibility.VISIBILITY_PUBLIC,
          ),
          iosNotificationOptions: const IOSNotificationOptions(),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.nothing(),
            // Do NOT pin the CPU awake. The service only needs to keep the
            // process alive to hold the socket; incoming packets / keepalive
            // pings wake the CPU on their own. allowWakeLock defaults to true,
            // which kept the CPU on 24/7 and was the main battery drain.
            allowWakeLock: false,
            allowWifiLock: false,
          ),
        );
        _initialized = true;
      }

      // startService REPORTS failure, it does not throw one — the old code
      // wrapped it in try/catch and assumed success, so every failure was
      // invisible.
      final result = await FlutterForegroundTask.startService(
        serviceId: 4711,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Tjena',
        notificationText: 'Connected — receiving messages',
        // Registers the task isolate, which exists solely so Android 14+ can
        // tell us the notification was swiped away.
        callback: bridgeKeepAliveCallback,
      );
      if (result is ServiceRequestFailure) {
        lastError = 'startService failed: ${result.error}';
        Logs().e('[BridgeKeepAlive] $lastError');
        return;
      }
      lastError = null;
      _lastText = 'Connected — receiving messages';
      Logs().i('[BridgeKeepAlive] foreground service started');
    } catch (e, s) {
      lastError = 'startService threw: $e';
      Logs().e('[BridgeKeepAlive] start failed', e, s);
    }
  }

  /// Update the persistent notification's body text, if it changed.
  static Future<void> _setText(String text) async {
    if (_lastText == text) return;
    await _postText(text);
  }

  /// Re-post the notification unconditionally, bringing it back if the user
  /// dismissed it. Needed on Android 13, which lets the notification be swiped
  /// away but delivers no `onNotificationDismissed` callback — so the app has
  /// no way to know, and simply re-asserts on every resume.
  ///
  /// `updateService` re-issues `NotificationManager.notify()` with the
  /// service's own id, which re-shows a dismissed notification; it is a no-op
  /// when the notification is already there.
  static Future<void> reassertNotification() async {
    if (!PlatformInfos.isAndroid) return;
    await _postText(_lastText ?? 'Connected — receiving messages');
  }

  static Future<void> _postText(String text) async {
    if (!await isRunning) return;
    _lastText = text;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Tjena',
        notificationText: text,
      );
    } catch (e) {
      Logs().d('[BridgeKeepAlive] updateService failed: $e');
    }
  }

  static Future<void> _stop() async {
    if (!await isRunning) return;
    _lastText = null;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
