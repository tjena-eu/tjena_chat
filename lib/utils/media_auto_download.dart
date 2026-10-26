// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/platform_infos.dart';

/// Per-chat control over whether image/video media loads by itself in the
/// timeline.
///
/// The global switch (Settings ▸ Chat ▸ "Show thumbnails…") stays the default;
/// a chat may override it in either direction, so a data-heavy group can be
/// silenced without turning thumbnails off everywhere — and one important chat
/// can keep loading while the global default is off.
///
/// Overrides live in SharedPreferences and are mirrored in a memory cache,
/// because the timeline reads this on every bubble build (a synchronous path).
///
/// Android's system Data Saver overrides everything: while it is actively
/// restricting the app, nothing auto-downloads and every image waits for a tap.
/// That mirrors what the user asked the OS for, so it deliberately wins over
/// both the per-chat override and the global setting.
abstract class MediaAutoDownload {
  static const _prefix = 'auto_download_media_';

  /// Handled in android/…/MainActivity.kt.
  static const _system = MethodChannel('tjena.chat/system');

  /// roomId → override. Absent means "follow the global setting".
  static final Map<String, bool> _overrides = {};

  /// Bumped whenever an override (or the Data Saver state) changes, so open
  /// timelines rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Cached Data Saver state — read on a platform channel, so it can't be
  /// awaited from the synchronous timeline path. Refreshed at start and on
  /// every app resume.
  static bool _dataSaver = false;

  /// Whether Android's Data Saver is currently restricting this app.
  static bool get dataSaverActive => _dataSaver;

  /// Load all stored overrides into memory. Must be awaited during app start,
  /// before the first timeline is built.
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefix)) continue;
        final value = prefs.getBool(key);
        if (value == null) continue;
        _overrides[key.substring(_prefix.length)] = value;
      }
    } catch (e) {
      Logs().w('[MediaAutoDownload] load failed: $e');
    }
    await refreshDataSaver();
  }

  /// Re-read the system Data Saver state. Call at start and whenever the app is resumed — the
  /// user may have flipped it while away, or moved between metered and
  /// unmetered networks.
  static Future<void> refreshDataSaver() async {
    if (!PlatformInfos.isAndroid) return;
    try {
      final active =
          await _system.invokeMethod<bool>('isDataSaverRestricted') ?? false;
      if (active != _dataSaver) {
        _dataSaver = active;
        revision.value++;
      }
    } catch (e) {
      Logs().d('[MediaAutoDownload] data saver check failed: $e');
    }
  }

  /// Whether media in [roomId] should download and render on its own.
  ///
  /// False under Data Saver regardless of the chat's own setting — the image
  /// then shows its embedded preview with a tap-to-load overlay.
  static bool enabledFor(String roomId) {
    if (_dataSaver) return false;
    return _overrides[roomId] ?? AppSettings.showThumbnailsInTimeline.value;
  }

  /// The chat's explicit override, or null when it follows the global setting.
  static bool? overrideFor(String roomId) => _overrides[roomId];

  /// Set (or, with null, clear) a chat's override.
  static Future<void> setOverride(String roomId, bool? enabled) async {
    if (enabled == null) {
      _overrides.remove(roomId);
    } else {
      _overrides[roomId] = enabled;
    }
    revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (enabled == null) {
        await prefs.remove('$_prefix$roomId');
      } else {
        await prefs.setBool('$_prefix$roomId', enabled);
      }
    } catch (e) {
      Logs().w('[MediaAutoDownload] save failed: $e');
    }
  }

  /// Drop a chat's override when the room is left/forgotten, so the key doesn't
  /// linger forever.
  static Future<void> forget(String roomId) => setOverride(roomId, null);
}
