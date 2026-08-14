// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

import 'date_time_extension.dart';
import 'file_description.dart';

/// Groups runs of consecutive, caption-less image messages from the same
/// sender (e.g. someone dropping a burst of WhatsApp photos into a chat) so
/// [ChatEventList] can render them as one small grid bubble instead of
/// flooding the timeline with N separate bubbles.
class MediaGroup {
  /// eventId of a run's anchor (its newest/bottom-most event, i.e. the one
  /// [ChatEventList] still renders a `Message` for) -> every event in the
  /// run, oldest first. Only present for runs of 2 or more.
  final Map<String, List<Event>> groupsByAnchor;

  /// eventIds of every non-anchor member of a run. [ChatEventList] renders
  /// nothing for these — their content is shown inside the anchor's grid.
  final Set<String> hiddenEventIds;

  const MediaGroup._(this.groupsByAnchor, this.hiddenEventIds);

  static const empty = MediaGroup._({}, {});

  static bool _isGroupable(Event event, Timeline timeline) =>
      event.type == EventTypes.Message &&
      event.messageType == MessageTypes.Image &&
      !event.redacted &&
      event.fileDescription == null &&
      !event.hasAggregatedEvents(timeline, RelationshipTypes.reaction) &&
      !event.hasAggregatedEvents(timeline, RelationshipTypes.thread);

  /// [events] must be newest-first, matching `Timeline.events` /
  /// `filterByVisibleInGui`'s order (so `events[i+1]` is older than
  /// `events[i]`).
  factory MediaGroup.build(List<Event> events, Timeline timeline) {
    final groups = <String, List<Event>>{};
    final hidden = <String>{};
    var i = 0;
    while (i < events.length) {
      final anchor = events[i];
      if (!_isGroupable(anchor, timeline)) {
        i++;
        continue;
      }
      final run = [anchor];
      var j = i + 1;
      while (j < events.length &&
          _isGroupable(events[j], timeline) &&
          events[j].senderId == anchor.senderId &&
          anchor.originServerTs.sameEnvironment(events[j].originServerTs)) {
        run.add(events[j]);
        j++;
      }
      if (run.length > 1) {
        // Oldest first, for natural reading order inside the grid.
        groups[anchor.eventId] = run.reversed.toList();
        hidden.addAll(run.skip(1).map((e) => e.eventId));
      }
      i = j;
    }
    return groups.isEmpty ? empty : MediaGroup._(groups, hidden);
  }
}
