// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:geolocator/geolocator.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_location_constants.dart';

/// Drives an outgoing live-location share: publishes the `m.beacon_info` state
/// event, streams the device position (in the background via a foreground
/// service on Android), throttles and sends `m.beacon` updates referencing the
/// beacon_info, and stops cleanly on timeout or user request.
///
/// One active share at a time (keeps the UX and battery cost predictable).
class LiveLocationManager extends ChangeNotifier {
  LiveLocationManager._();
  static final LiveLocationManager instance = LiveLocationManager._();

  static const _prefsKey = 'tjena.live_location.active';

  // Minimum time between sent beacons, to bound traffic/battery.
  static const _minSendInterval = Duration(seconds: 8);

  Room? _room;
  String? _beaconInfoEventId;
  DateTime _expiry = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<Position>? _positionSub;
  Timer? _stopTimer;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isSharing => _beaconInfoEventId != null;
  String? get activeRoomId => _room?.id;
  DateTime get expiry => _expiry;

  /// Begin sharing live location into [room] for [duration].
  ///
  /// Caller is responsible for having obtained location permission (incl.
  /// background "allow all the time" on Android) before calling this.
  Future<void> startSharing(
    Room room, {
    required Duration duration,
    String? description,
  }) async {
    if (isSharing) await stopSharing();

    final cappedDuration =
        duration > LiveLocationKeys.maxTimeout ? LiveLocationKeys.maxTimeout : duration;
    final startTs = DateTime.now().millisecondsSinceEpoch;

    final beaconInfoEventId = await room.client.setRoomStateWithKey(
      room.id,
      LiveLocationKeys.beaconInfoType,
      room.client.userID!,
      {
        LiveLocationKeys.description: description,
        LiveLocationKeys.live: true,
        LiveLocationKeys.timeout: cappedDuration.inMilliseconds,
        LiveLocationKeys.ts: startTs,
        LiveLocationKeys.asset: {'type': LiveLocationKeys.assetTypeSelf},
      },
    );

    _room = room;
    _beaconInfoEventId = beaconInfoEventId;
    _expiry = DateTime.fromMillisecondsSinceEpoch(
      startTs + cappedDuration.inMilliseconds,
    );
    _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

    await _persist();
    _startPositionStream();

    // Schedule automatic stop at expiry.
    _stopTimer?.cancel();
    _stopTimer = Timer(cappedDuration, stopSharing);

    notifyListeners();

    // Send an immediate first beacon so receivers see a position right away.
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      await _sendBeacon(pos, force: true);
    } catch (e) {
      Logs().w('[LiveLocation] initial position failed', e);
    }
  }

  void _startPositionStream() {
    final settings = _locationSettings();
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(
      (pos) => unawaited(_sendBeacon(pos)),
      onError: (Object e, StackTrace s) =>
          Logs().w('[LiveLocation] position stream error', e, s),
    );
  }

  LocationSettings _locationSettings() {
    const distanceFilter = 5; // metres
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
        // A foreground service keeps location flowing while backgrounded.
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Sharing live location',
          notificationText: 'tjena!chat is sharing your location',
          enableWakeLock: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
        pauseLocationUpdatesAutomatically: false,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: distanceFilter,
    );
  }

  Future<void> _sendBeacon(Position pos, {bool force = false}) async {
    final room = _room;
    final beaconInfoEventId = _beaconInfoEventId;
    if (room == null || beaconInfoEventId == null) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastSent) < _minSendInterval) return;
    if (now.isAfter(_expiry)) {
      await stopSharing();
      return;
    }
    _lastSent = now;

    try {
      await room.sendEvent(
        {
          'm.relates_to': {
            'rel_type': 'm.reference',
            'event_id': beaconInfoEventId,
          },
          LiveLocationKeys.location: {
            'uri': GeoUri.format(pos.latitude, pos.longitude, pos.accuracy),
            LiveLocationKeys.description: null,
          },
          LiveLocationKeys.ts: now.millisecondsSinceEpoch,
        },
        type: LiveLocationKeys.beaconType,
      );
    } catch (e, s) {
      Logs().w('[LiveLocation] sending beacon failed', e, s);
    }
  }

  /// Stop the active share: end the position stream and flag beacon_info dead.
  Future<void> stopSharing() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    await _positionSub?.cancel();
    _positionSub = null;

    final room = _room;
    if (room != null) {
      try {
        await room.client.setRoomStateWithKey(
          room.id,
          LiveLocationKeys.beaconInfoType,
          room.client.userID!,
          {
            LiveLocationKeys.live: false,
            LiveLocationKeys.timeout:
                _expiry.millisecondsSinceEpoch -
                DateTime.now().millisecondsSinceEpoch,
            LiveLocationKeys.ts: DateTime.now().millisecondsSinceEpoch,
            LiveLocationKeys.asset: {'type': LiveLocationKeys.assetTypeSelf},
          },
        );
      } catch (e, s) {
        Logs().w('[LiveLocation] failed to mark beacon stopped', e, s);
      }
    }

    _room = null;
    _beaconInfoEventId = null;
    await _clearPersisted();
    notifyListeners();
  }

  /// Resume an active share after an app restart (within its timeout window).
  Future<void> restoreIfActive(Client client) async {
    if (isSharing) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey);
      if (raw == null || raw.length != 3) return;
      final roomId = raw[0];
      final beaconInfoEventId = raw[1];
      final expiryMs = int.tryParse(raw[2]) ?? 0;
      final expiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
      if (DateTime.now().isAfter(expiry)) {
        await _clearPersisted();
        return;
      }
      final room = client.getRoomById(roomId);
      if (room == null) return;

      _room = room;
      _beaconInfoEventId = beaconInfoEventId;
      _expiry = expiry;
      _startPositionStream();
      _stopTimer?.cancel();
      _stopTimer = Timer(expiry.difference(DateTime.now()), stopSharing);
      notifyListeners();
    } catch (e, s) {
      Logs().w('[LiveLocation] restore failed', e, s);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, [
      _room!.id,
      _beaconInfoEventId!,
      _expiry.millisecondsSinceEpoch.toString(),
    ]);
  }

  Future<void> _clearPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
