// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_infos.dart';

/// Cleans up after the built-in (on-device) bridges were removed: WhatsApp
/// in 2.8.0, Signal in 2.9.0.
///
/// Those bridges kept their chats as device-local rooms ("!wa_…:local",
/// "!sig_…:local") in the Matrix database, their settings in
/// SharedPreferences, and their sessions under `<app support>/tjena_bridge`.
/// Without this, their chats would stay in the chat list forever with
/// nothing updating them.
///
/// The WhatsApp/Signal side is not logged out (that code is gone): the old
/// "tjena" entry can be removed under Linked devices in those apps.
abstract class LegacyBridgeCleanup {
  static const _waDoneKey = 'legacy_wa_bridge_removed_v1';
  static const _signalDoneKey = 'legacy_signal_bridge_removed_v1';

  static bool _isLocalBridgeRoom(String id) =>
      (id.startsWith('!wa_') || id.startsWith('!sig_')) &&
      id.endsWith(':local');

  static Future<void> run(Client client) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_signalDoneKey) == true) return;
    try {
      // The Signal bridge's background service (persistent notification).
      try {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
      } catch (_) {}

      // Rooms and spaces of the old bridges (also archived ones).
      final ids = <String>{
        for (final r in client.rooms)
          if (_isLocalBridgeRoom(r.id)) r.id,
        for (final a in client.archivedRooms)
          if (_isLocalBridgeRoom(a.room.id)) a.room.id,
      };
      for (final id in ids) {
        try {
          await client.database.forgetRoom(id);
        } catch (_) {}
      }
      client.rooms.removeWhere((r) => _isLocalBridgeRoom(r.id));
      client.archivedRooms.removeWhere((a) => _isLocalBridgeRoom(a.room.id));

      // Their settings.
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith('wa_bridge_') ||
            key == 'wa_link_mode' ||
            key == 'wa_default_backfill_days' ||
            key == 'eu.tjena.local_bridges_enabled' ||
            key == 'eu.tjena.local_bridge_background_service') {
          await prefs.remove(key);
        }
      }

      // Their sessions, keys and caches.
      if (PlatformInfos.isAndroid) {
        final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/tjena_bridge',
        );
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      Logs().i(
        '[LegacyBridgeCleanup] removed ${ids.length} rooms of the old built-in bridges',
      );
      await prefs.setBool(_waDoneKey, true);
      await prefs.setBool(_signalDoneKey, true);
    } catch (e, s) {
      Logs().w('[LegacyBridgeCleanup] failed, will retry next start', e, s);
    }
  }
}
