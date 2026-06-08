// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/live_location/live_location_constants.dart';
import 'package:matrix/matrix.dart';

extension VisibleInGuiExtension on List<Event> {
  List<Event> filterByVisibleInGui({
    String? exceptionEventId,
    String? threadId,
  }) => where((event) {
    if (threadId != null &&
        event.relationshipType != RelationshipTypes.reaction) {
      if ((event.relationshipType != RelationshipTypes.thread ||
              event.relationshipEventId != threadId) &&
          event.eventId != threadId) {
        return false;
      }
    } else if (event.relationshipType == RelationshipTypes.thread) {
      return false;
    }
    return event.isVisibleInGui || event.eventId == exceptionEventId;
  }).toList();
}

extension IsStateExtension on Event {
  bool get isVisibleInGui {
    // Live location: hide the frequent beacon updates (rendered inside the
    // beacon_info tile), but always show the beacon_info tile itself even
    // though the SDK considers these types "unknown".
    if (LiveLocationKeys.isBeacon(type)) return false;
    if (LiveLocationKeys.isBeaconInfo(type)) {
      return !(AppSettings.hideRedactedEvents.value && redacted);
    }
    return
        // always filter out edit and reaction relationships
        !{
          RelationshipTypes.edit,
          RelationshipTypes.reaction,
        }.contains(relationshipType) &&
        // always filter out m.key.* and other known but unimportant events
        !isKnownHiddenStates &&
        // event types to hide: redaction and reaction events
        // if a reaction has been redacted we also want it to be hidden in the timeline
        !{EventTypes.Reaction, EventTypes.Redaction}.contains(type) &&
        // if we enabled to hide all redacted events, don't show those
        (!AppSettings.hideRedactedEvents.value || !redacted) &&
        // if we enabled to hide all unknown events, don't show those
        (!AppSettings.hideUnknownEvents.value || isEventTypeKnown);
  }

  bool get isState => !{
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
  }.contains(type);

  bool get isCollapsedState => !{
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
    EventTypes.RoomCreate,
    EventTypes.RoomTombstone,
  }.contains(type);

  bool get isKnownHiddenStates =>
      {PollEventContent.responseType}.contains(type) ||
      type.startsWith('m.key.verification.');
}
