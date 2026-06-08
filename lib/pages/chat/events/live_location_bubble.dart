// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/chat/events/map_bubble.dart';
import 'package:fluffychat/utils/live_location/live_location_constants.dart';
import 'package:fluffychat/utils/live_location/live_location_manager.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Renders an `m.beacon_info` timeline event as a live-location tile: a map at
/// the latest reported position (from related `m.beacon` events), the live
/// status, and a stop control for the user's own active share.
///
/// It rebuilds whenever the timeline updates, so incoming beacons move the pin
/// while the chat is open.
class LiveLocationBubble extends StatelessWidget {
  final Event event;
  final Timeline timeline;

  const LiveLocationBubble({
    required this.event,
    required this.timeline,
    super.key,
  });

  /// The most recent beacon position related to this beacon_info, if any.
  GeoUri? _latestPosition() {
    Event? latest;
    var latestTs = -1;
    for (final e in timeline.events) {
      if (!LiveLocationKeys.isBeacon(e.type)) continue;
      if (e.relationshipEventId != event.eventId) continue;
      final tsRaw =
          e.content[LiveLocationKeys.ts] ?? e.content[LiveLocationKeys.tsStable];
      final ts =
          tsRaw is int ? tsRaw : e.originServerTs.millisecondsSinceEpoch;
      if (ts > latestTs) {
        latestTs = ts;
        latest = e;
      }
    }
    if (latest == null) return null;
    final loc = latest.content[LiveLocationKeys.location] ??
        latest.content[LiveLocationKeys.locationStable];
    if (loc is! Map) return null;
    return GeoUri.tryParse(loc['uri'] as String?);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = Matrix.of(context).client;

    final beacon = BeaconInfo.fromContent(
      eventId: event.eventId,
      userId: event.senderId,
      content: event.content,
    );

    // Current live status comes from the latest beacon_info state for this user,
    // so a "stopped" update is reflected even on the original start tile.
    final currentState = event.room
        .getState(LiveLocationKeys.beaconInfoType, event.senderId)
        ?.content;
    final flaggedLive = (currentState?[LiveLocationKeys.live] ?? beacon?.live) == true;
    final isActive = flaggedLive && (beacon?.isActive ?? false);

    final isOwn = event.senderId == client.userID;
    final position = _latestPosition();

    final statusText = isActive
        ? 'Live until ${TimeOfDay.fromDateTime(beacon!.expiry).format(context)}'
        : 'Live location ended';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? Icons.location_on : Icons.location_off,
              size: 18,
              color: isActive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Text(
              'Live location',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (position != null)
          MapBubble(latitude: position.latitude, longitude: position.longitude)
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              isActive ? 'Waiting for location…' : 'No location received',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          statusText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        if (isOwn && isActive)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: LiveLocationManager.instance.stopSharing,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Stop sharing'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
