// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Event types and content keys for Matrix live location sharing
/// (MSC3489 beacons / MSC3672 streaming location, MSC3488 location asset).
///
/// We send the stable types with MSC3488-prefixed content fields, which is
/// what current Element clients emit, and we accept both stable and unstable
/// variants when receiving so we interoperate broadly.
class LiveLocationKeys {
  // Beacon info (state event, state_key = sender mxid).
  static const beaconInfoType = 'm.beacon_info';
  static const beaconInfoTypeUnstable = 'org.matrix.msc3672.beacon_info';

  // Beacon (message event referencing the beacon_info).
  static const beaconType = 'm.beacon';
  static const beaconTypeUnstable = 'org.matrix.msc3672.beacon';

  // Content fields (MSC3488).
  static const location = 'org.matrix.msc3488.location';
  static const locationStable = 'm.location';
  static const asset = 'org.matrix.msc3488.asset';
  static const assetStable = 'm.asset';
  static const ts = 'org.matrix.msc3488.ts';
  static const tsStable = 'm.ts';

  static const live = 'live';
  static const timeout = 'timeout';
  static const description = 'description';
  static const assetTypeSelf = 'm.self';

  /// Max session length we allow (8 hours), matching the dialog options.
  static const maxTimeout = Duration(hours: 8);

  /// Returns true if [type] is a beacon_info state event (stable or unstable).
  static bool isBeaconInfo(String type) =>
      type == beaconInfoType || type == beaconInfoTypeUnstable;

  /// Returns true if [type] is a beacon message event (stable or unstable).
  static bool isBeacon(String type) =>
      type == beaconType || type == beaconTypeUnstable;
}

/// A parsed view of a `m.beacon_info` state event.
class BeaconInfo {
  /// The event id of the beacon_info state event (beacons reference this).
  final String eventId;

  /// The mxid of the user sharing their location (the state_key / sender).
  final String userId;
  final bool live;

  /// When the share started (ms since epoch).
  final int startTs;

  /// How long the share is meant to last.
  final Duration timeout;
  final String? description;

  BeaconInfo({
    required this.eventId,
    required this.userId,
    required this.live,
    required this.startTs,
    required this.timeout,
    this.description,
  });

  /// When the share is scheduled to expire.
  DateTime get expiry =>
      DateTime.fromMillisecondsSinceEpoch(startTs + timeout.inMilliseconds);

  /// Whether the share is currently active: flagged live and not yet expired.
  bool get isActive => live && DateTime.now().isBefore(expiry);

  static BeaconInfo? fromContent({
    required String eventId,
    required String userId,
    required Map<String, dynamic> content,
  }) {
    if (content[LiveLocationKeys.live] is! bool) return null;
    final tsRaw = content[LiveLocationKeys.ts] ?? content[LiveLocationKeys.tsStable];
    final timeoutRaw = content[LiveLocationKeys.timeout];
    return BeaconInfo(
      eventId: eventId,
      userId: userId,
      live: content[LiveLocationKeys.live] as bool,
      startTs: tsRaw is int ? tsRaw : DateTime.now().millisecondsSinceEpoch,
      timeout: Duration(
        milliseconds: timeoutRaw is int ? timeoutRaw : 60 * 60 * 1000,
      ),
      description: content[LiveLocationKeys.description] as String?,
    );
  }
}

/// Parses a `geo:` URI (e.g. "geo:51.5,-0.1;u=10") into coordinates.
class GeoUri {
  final double latitude;
  final double longitude;
  final double? uncertainty;

  GeoUri(this.latitude, this.longitude, this.uncertainty);

  static GeoUri? tryParse(String? uri) {
    if (uri == null || !uri.startsWith('geo:')) return null;
    try {
      final body = uri.substring(4);
      final parts = body.split(';');
      final coords = parts.first.split(',');
      if (coords.length < 2) return null;
      final lat = double.parse(coords[0]);
      final lon = double.parse(coords[1]);
      double? u;
      for (final p in parts.skip(1)) {
        if (p.startsWith('u=')) u = double.tryParse(p.substring(2));
      }
      return GeoUri(lat, lon, u);
    } catch (_) {
      return null;
    }
  }

  static String format(double lat, double lon, double? accuracy) =>
      accuracy != null ? 'geo:$lat,$lon;u=$accuracy' : 'geo:$lat,$lon';
}
