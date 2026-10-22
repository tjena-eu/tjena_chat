// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/bridge_keepalive.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tjena_bridge/bridge_room_store.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

/// Turns the old built-in (on-device) WhatsApp/Signal bridge on and off.
///
/// The built-in bridge is being phased out in favour of the personal bridge
/// (tjena Bridge app on a phone at home), so it is an experimental opt-in:
/// new installs don't start it at all. Users who already had an account
/// linked keep it ([migrate]).
class LocalBridgeControl {
  LocalBridgeControl._();

  static bool get enabled =>
      PlatformInfos.isAndroid && AppSettings.localBridgesEnabled.value;

  static bool _running = false;

  /// One-time decision for installs from before the opt-in existed: keep the
  /// built-in bridge on if it has a linked WhatsApp or Signal account.
  static Future<void> migrate() async {
    if (!PlatformInfos.isAndroid) return;
    if (AppSettings.store.get(AppSettings.localBridgesEnabled.key) != null) {
      return;
    }
    var keep = false;
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/tjena_bridge',
      );
      if (await dir.exists() && !await dir.list().isEmpty) {
        await TjenaBridge.instance.start();
        final accounts = await TjenaBridge.instance.listAccounts();
        final signal = await TjenaBridge.instance.getSignalState();
        keep = accounts.any((a) => a['linked'] == true) || signal.linked;
        if (!keep) await TjenaBridge.instance.stop();
      }
    } catch (e) {
      Logs().w('[LocalBridge] migration check failed: $e');
    }
    Logs().i('[LocalBridge] built-in bridge ${keep ? 'kept on' : 'off'}');
    await AppSettings.localBridgesEnabled.setItem(keep);
  }

  /// Starts the native bridge if enabled. Idempotent.
  static Future<void> startIfEnabled() async {
    if (!enabled || _running) return;
    _running = true;
    try {
      BridgeRoomStore.instance.startListening();
      await TjenaBridge.instance.start();
      await BridgeKeepAlive.refresh();
    } catch (e) {
      Logs().w('[LocalBridge] start failed: $e');
    }
  }

  /// Turn the built-in bridge on or off at runtime.
  static Future<void> setEnabled(bool on) async {
    await AppSettings.localBridgesEnabled.setItem(on);
    if (on) {
      await startIfEnabled();
      return;
    }
    _running = false;
    try {
      await TjenaBridge.instance.stop();
    } catch (e) {
      Logs().w('[LocalBridge] stop failed: $e');
    }
    BridgeRoomStore.instance.stopListening();
    await BridgeKeepAlive.refresh();
  }

  /// Turn the background (foreground-service) keep-alive on or off.
  static Future<void> setBackgroundService(bool on) async {
    await AppSettings.localBridgeBackgroundService.setItem(on);
    await BridgeKeepAlive.refresh();
  }
}
