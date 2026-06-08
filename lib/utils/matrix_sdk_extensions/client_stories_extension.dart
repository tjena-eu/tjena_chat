// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

/// Story sharing on top of MSC3588 "stories rooms": a per-user encrypted room
/// (creation type `msc3588.stories.stories-room`) whose recent messages are the
/// user's story posts. Posts expire after [storyLifetime] (24h) via room
/// retention and our own client-side filtering.
///
/// This is the lighter, status-list-integrated variant of FluffyChat's original
/// stories feature; the storage model is kept compatible with it.
extension ClientStoriesExtension on Client {
  static const String storiesRoomType = 'msc3588.stories.stories-room';
  static const Duration storyLifetime = Duration(hours: 24);

  /// Direct-chat partners — the people we invite to and see stories from.
  List<User> get storyContacts => rooms
      .where((room) => room.isDirectChat && room.directChatMatrixID != null)
      .map(
        (room) =>
            room.unsafeGetUserFromMemoryOrFallback(room.directChatMatrixID!),
      )
      .toList();

  /// Every story room we are a member of (our own + contacts' shared with us).
  List<Room> get storiesRooms =>
      rooms.where((room) => room.isStoryRoom).toList();

  /// Our own story room (the one we have permission to post in), if any.
  Room? get myStoriesRoom {
    final candidates = storiesRooms.where((room) => room.canSendDefaultMessages);
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Story rooms that currently have at least one non-expired post.
  List<Room> get storiesRoomsWithActivePosts =>
      storiesRooms.where((room) => room.hasActiveStory).toList();

  /// Find our story room or create one, inviting our direct-chat contacts so
  /// they can see the posts.
  Future<Room> getOrCreateMyStoriesRoom() async {
    final existing = myStoriesRoom;
    if (existing != null) return existing;

    final invites = storyContacts.map((u) => u.id).toSet().toList();
    final roomId = await createRoom(
      creationContent: {'type': storiesRoomType},
      preset: CreateRoomPreset.privateChat,
      powerLevelContentOverride: {'events_default': 100},
      name: 'Stories from ${userID!.localpart}',
      topic:
          'Story sharing room (MSC3588). Best viewed in FluffyChat / tjena!chat.',
      initialState: [
        StateEvent(
          type: EventTypes.Encryption,
          stateKey: '',
          content: {'algorithm': 'm.megolm.v1.aes-sha2'},
        ),
        StateEvent(
          type: 'm.room.retention',
          stateKey: '',
          content: {
            'min_lifetime': storyLifetime.inMilliseconds,
            'max_lifetime': storyLifetime.inMilliseconds,
          },
        ),
      ],
      invite: invites.isEmpty ? null : invites,
    );

    if (getRoomById(roomId) == null) {
      // Wait until the (encrypted) room shows up in sync before using it.
      await onSync.stream.firstWhere(
        (sync) =>
            sync.rooms?.join?[roomId]?.state
                ?.any((state) => state.type == EventTypes.Encrypted) ??
            false,
      );
    }
    final room = getRoomById(roomId);
    if (room == null) {
      throw Exception('Failed to create stories room.');
    }
    return room;
  }
}

extension StoryRoomExtension on Room {
  bool get isStoryRoom =>
      getState(EventTypes.RoomCreate)?.content.tryGet<String>('type') ==
      ClientStoriesExtension.storiesRoomType;

  /// Whether posting here is allowed for us (i.e. this is effectively ours).
  bool get canSendDefaultMessages =>
      ownPowerLevel.level >= (_defaultEventsPowerLevel ?? 0);

  int? get _defaultEventsPowerLevel => getState(EventTypes.RoomPowerLevels)
      ?.content
      .tryGet<int>('events_default');

  /// Story post events from the last 24h, oldest first (viewing order).
  List<Event> storyPosts(Timeline timeline) {
    final cutoff = DateTime.now().subtract(ClientStoriesExtension.storyLifetime);
    final posts = timeline.events
        .where(
          (e) =>
              e.type == EventTypes.Message &&
              !e.redacted &&
              e.originServerTs.isAfter(cutoff),
        )
        .toList();
    posts.sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    return posts;
  }

  /// Cheap check (no timeline) for whether the last message is within 24h.
  bool get hasActiveStory {
    final last = lastEvent;
    if (last == null || last.type != EventTypes.Message) return false;
    final cutoff = DateTime.now().subtract(ClientStoriesExtension.storyLifetime);
    return last.originServerTs.isAfter(cutoff);
  }

  /// The author/owner of this story room (its creator).
  String? get storyAuthorId =>
      getState(EventTypes.RoomCreate)?.senderId;
}
