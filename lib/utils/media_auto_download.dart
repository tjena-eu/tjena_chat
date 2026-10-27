// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/platform_infos.dart';

/// Which network the phone is on, as far as media downloads are concerned.
enum MediaNetwork {
  /// Unmetered (Wi-Fi, Ethernet).
  wifi,

  /// Metered (mobile data, metered hotspot).
  mobile,

  /// Android's Data Saver is restricting this app right now (only happens on
  /// a metered network).
  dataSaver,
}

/// Decides whether photos and videos load by themselves in the timeline.
///
/// Settings ▸ Chats ▸ "Auto-download media" holds one switch per media type and
/// network (Wi-Fi / mobile data / Data Saver). A chat may override that: off
/// means everything waits for a tap there, on means it auto-downloads on Wi-Fi
/// and mobile data (Data Saver still follows the global setting).
///
/// Saving to the gallery is a separate setting (auto-save); it saves whatever
/// got downloaded, automatically or by tap.
///
/// The timeline reads this on every bubble build (a synchronous path), so the
/// overrides and the network state are cached in memory.
abstract class MediaAutoDownload {
  static const _prefix = 'auto_download_media_';

  /// Handled in android/…/MainActivity.kt.
  static const _system = MethodChannel('tjena.chat/system');

  /// roomId → override. Absent means "follow the global setting".
  static final Map<String, bool> _overrides = {};

  /// Bumped whenever an override, a setting or the network changes, so open
  /// timelines rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Last known network. Wi-Fi until told otherwise (desktop/web never are).
  static MediaNetwork _network = MediaNetwork.wifi;

  static MediaNetwork get network => _network;

  /// Whether Android's Data Saver is currently restricting this app.
  static bool get dataSaverActive => _network == MediaNetwork.dataSaver;

  /// Load all stored overrides into memory and start following the network.
  /// Must be awaited during app start, before the first timeline is built.
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
    if (PlatformInfos.isAndroid) {
      _system.setMethodCallHandler((call) async {
        if (call.method == 'networkChanged') _apply(call.arguments);
      });
    }
    await refreshDataSaver();
  }

  /// Re-read the network and Data Saver state. Called at start and on every
  /// app resume; changes while running arrive as "networkChanged".
  static Future<void> refreshDataSaver() async {
    if (!PlatformInfos.isAndroid) return;
    try {
      _apply(await _system.invokeMethod<Object?>('networkState'));
    } catch (e) {
      Logs().d('[MediaAutoDownload] network check failed: $e');
    }
  }

  static void _apply(Object? state) {
    if (state is! Map) return;
    final MediaNetwork next;
    if (state['dataSaver'] == true) {
      next = MediaNetwork.dataSaver;
    } else if (state['type'] == 'mobile') {
      next = MediaNetwork.mobile;
    } else {
      // Offline counts as Wi-Fi: nothing downloads anyway, and coming back
      // on Wi-Fi shouldn't need another event to unlock media.
      next = MediaNetwork.wifi;
    }
    if (next != _network) {
      _network = next;
      revision.value++;
    }
  }

  /// The global setting for one media type on one network.
  static AppSettings<bool> settingFor(
    MediaNetwork network, {
    required bool video,
  }) => switch ((network, video)) {
    (MediaNetwork.wifi, false) => AppSettings.autoDownloadPhotosWifi,
    (MediaNetwork.mobile, false) => AppSettings.autoDownloadPhotosMobile,
    (MediaNetwork.dataSaver, false) => AppSettings.autoDownloadPhotosDataSaver,
    (MediaNetwork.wifi, true) => AppSettings.autoDownloadVideosWifi,
    (MediaNetwork.mobile, true) => AppSettings.autoDownloadVideosMobile,
    (MediaNetwork.dataSaver, true) => AppSettings.autoDownloadVideosDataSaver,
  };

  /// Change a global setting and refresh open timelines.
  static Future<void> setSetting(
    MediaNetwork network, {
    required bool video,
    required bool value,
  }) async {
    await settingFor(network, video: video).setItem(value);
    revision.value++;
  }

  /// Whether photos ([video] false) or videos in [roomId] download on their
  /// own on the current network.
  static bool enabledFor(String roomId, {bool video = false}) {
    final override = _overrides[roomId];
    if (override == false) return false;
    if (override == true && _network != MediaNetwork.dataSaver) return true;
    return settingFor(_network, video: video).value;
  }

  /// Whether this event's media (photo or video) auto-downloads.
  static bool enabledForEvent(Event event) =>
      enabledFor(event.room.id, video: event.messageType == MessageTypes.Video);

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
