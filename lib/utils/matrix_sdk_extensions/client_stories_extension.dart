// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
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

  /// How long a story stays visible. Configurable via settings.
  static Duration get storyLifetime =>
      Duration(hours: AppSettings.storiesRetentionHours.value);

  /// Account-data key for the explicitly selected story recipients
  /// (used when the send scope is 'selected').
  static const String recipientsAccountDataType = 'chat.fluffy.stories_recipients';

  /// Account-data key storing the id of our "Stories" space.
  static const String spaceAccountDataType = 'chat.fluffy.stories_space';

  String? get storiesSpaceId =>
      accountData[spaceAccountDataType]?.content.tryGet<String>('id');

  /// Our joined "Stories" space, if it exists.
  Room? get storiesSpace {
    final id = storiesSpaceId;
    if (id == null) return null;
    final room = getRoomById(id);
    return (room != null && room.isSpace && room.membership == Membership.join)
        ? room
        : null;
  }

  /// Get our "Stories" space or create it. All story rooms are filed under it
  /// so they live in their own space instead of cluttering the chat list.
  Future<Room> getOrCreateStoriesSpace() async {
    final existing = storiesSpace;
    if (existing != null) return existing;

    final roomId = await createRoom(
      creationContent: {'type': 'm.space'},
      preset: CreateRoomPreset.privateChat,
      name: 'Stories',
      topic: 'Your stories and the stories shared with you.',
    );
    if (getRoomById(roomId) == null) {
      await onSync.stream.firstWhere(
        (sync) => sync.rooms?.join?[roomId] != null,
      );
    }
    await setAccountData(userID!, spaceAccountDataType, {'id': roomId});
    final room = getRoomById(roomId);
    if (room == null) throw Exception('Failed to create stories space.');
    return room;
  }

  /// File [room] under our Stories space (creating the space on first use).
  Future<void> addRoomToStoriesSpace(Room room) async {
    try {
      final space = await getOrCreateStoriesSpace();
      final alreadyChild =
          space.spaceChildren.any((c) => c.roomId == room.id);
      if (!alreadyChild) await space.setSpaceChild(room.id);
    } catch (e) {
      Logs().w('[Stories] failed to add ${room.id} to stories space', e);
    }
  }

  List<String> get storiesSelectedRecipients =>
      accountData[recipientsAccountDataType]?.content.tryGetList<String>(
        'users',
      ) ??
      [];

  Future<void> setStoriesSelectedRecipients(List<String> users) =>
      setAccountData(userID!, recipientsAccountDataType, {'users': users});

  /// The set of user ids who should receive my stories, derived from the
  /// send-scope setting and always intersected with my *current* direct-chat
  /// contacts (so removed/deleted chats drop out automatically).
  Set<String> get desiredStoryRecipients {
    final contacts = storyContacts.map((u) => u.id).toSet();
    switch (AppSettings.storiesSendScope.value) {
      case 'none':
        return {};
      case 'selected':
        return storiesSelectedRecipients.toSet().intersection(contacts);
      case 'all':
      default:
        return contacts;
    }
  }

  /// Our own homeserver domain (e.g. "tjena.eu").
  String? get _ownDomain => userID?.domain;

  /// Whether [matrixId] lives on our own homeserver. Stories are restricted to
  /// our federation/homeserver, so cross-server users are excluded.
  bool isSameHomeserver(String matrixId) =>
      _ownDomain != null && matrixId.domain == _ownDomain;

  /// Direct-chat partners on our own homeserver — the only people we invite to
  /// and see stories from (stories are limited to our federation).
  List<User> get storyContacts => rooms
      .where(
        (room) =>
            room.isDirectChat &&
            room.directChatMatrixID != null &&
            isSameHomeserver(room.directChatMatrixID!),
      )
      .map(
        (room) =>
            room.unsafeGetUserFromMemoryOrFallback(room.directChatMatrixID!),
      )
      .toList();

  /// Every story room we are a member of (our own + contacts' shared with us).
  List<Room> get storiesRooms =>
      rooms.where((room) => room.isStoryRoom).toList();

  /// Our own story room — the one we created (so we can post in it). Identified
  /// by the room creator, not by a power-level check (which can be wrong before
  /// the power_levels state has synced and would match rooms we were only
  /// invited to).
  Room? get myStoriesRoom {
    final candidates = storiesRooms.where(
      (room) =>
          room.storyAuthorId == userID &&
          room.membership == Membership.join,
    );
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Story rooms (from our own homeserver) that currently have at least one
  /// non-expired post.
  List<Room> get storiesRoomsWithActivePosts => storiesRooms.where((room) {
    final author = room.storyAuthorId;
    return room.hasActiveStory &&
        author != null &&
        (author == userID || isSameHomeserver(author));
  }).toList();

  /// Find our story room or create one, inviting the desired recipients so
  /// they can see the posts. Existing rooms get their invite list re-synced.
  Future<Room> getOrCreateMyStoriesRoom() async {
    final existing = myStoriesRoom;
    if (existing != null) {
      await syncMyStoryRoomInvites();
      await addRoomToStoriesSpace(existing);
      return existing;
    }

    final invites = desiredStoryRecipients.toList();
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
    await addRoomToStoriesSpace(room);
    return room;
  }

  /// Bring my story room's member list in line with [desiredStoryRecipients]:
  /// invite anyone missing and remove anyone who should no longer receive
  /// (e.g. contacts I deleted, or people removed from a 'selected' list).
  Future<void> syncMyStoryRoomInvites() async {
    final room = myStoriesRoom;
    if (room == null) return;
    final desired = desiredStoryRecipients;

    final participants = await room.requestParticipants();
    final current = participants
        .where(
          (u) =>
              u.id != userID &&
              (u.membership == Membership.join ||
                  u.membership == Membership.invite),
        )
        .map((u) => u.id)
        .toSet();

    for (final id in desired.difference(current)) {
      try {
        await room.invite(id);
      } catch (e) {
        Logs().w('[Stories] failed to invite $id', e);
      }
    }
    for (final id in current.difference(desired)) {
      try {
        await room.kick(id);
      } catch (e) {
        Logs().w('[Stories] failed to remove $id', e);
      }
    }
  }

  /// Auto-join applicable incoming story-room invites. Non-destructive: it only
  /// *joins* same-homeserver contacts' story rooms (when enabled and receiving),
  /// and only *rejects* a clearly-identified story room that is cross-server or
  /// when receiving is set to 'none'. Undetected invites are left untouched so
  /// they remain visible and can be accepted manually (recoverable).
  Future<void> applyStoriesReceivePolicy() async {
    if (!AppSettings.storiesEnabled.value) return; // off: do nothing
    final receiveAll = AppSettings.storiesReceiveScope.value != 'none';
    for (final room in storiesRooms) {
      final author = room.storyAuthorId;
      if (author == userID) continue; // never touch our own
      try {
        final accept =
            receiveAll && author != null && isSameHomeserver(author);
        if (accept) {
          if (room.membership == Membership.invite) await room.join();
          await addRoomToStoriesSpace(room);
        } else if (author != null) {
          // Known author but not acceptable (cross-server, or receiving none):
          // reject/leave. Undetected rooms (author == null) are left alone.
          if (room.membership == Membership.invite ||
              room.membership == Membership.join) {
            await room.leave();
          }
        }
      } catch (e) {
        Logs().w('[Stories] receive policy failed for ${room.id}', e);
      }
    }
  }

  /// Turn stories on: create our story room + space (inviting contacts) and
  /// auto-join applicable incoming story rooms.
  Future<void> enableStories() async {
    await AppSettings.storiesEnabled.setItem(true);
    await getOrCreateMyStoriesRoom();
    await applyStoriesReceivePolicy();
  }

  /// Turn stories off. Non-destructive — just flips the flag; existing rooms are
  /// left in place (use [leaveAllStoryRooms] to clean up).
  Future<void> disableStories() async {
    await AppSettings.storiesEnabled.setItem(false);
  }

  /// Leave every story room (own + received), clearing old/stuck rooms. Used by
  /// the "clean up" action in settings.
  Future<void> leaveAllStoryRooms() async {
    for (final room in storiesRooms) {
      if (room.membership == Membership.leave) continue;
      try {
        await room.leave();
      } catch (e) {
        Logs().w('[Stories] failed to leave ${room.id}', e);
      }
    }
  }

  /// Redact every story post in my story room (delete all my stories now).
  Future<void> deleteMyStories() async {
    final room = myStoriesRoom;
    if (room == null) return;
    final timeline = await room.getTimeline();
    final posts = timeline.events
        .where((e) => e.type == EventTypes.Message && !e.redacted)
        .toList();
    for (final post in posts) {
      try {
        await room.redactEvent(post.eventId);
      } catch (e) {
        Logs().w('[Stories] failed to delete story post', e);
      }
    }
  }
}

extension StoryRoomExtension on Room {
  bool get isStoryRoom {
    if (getState(EventTypes.RoomCreate)?.content.tryGet<String>('type') ==
        ClientStoriesExtension.storiesRoomType) {
      return true;
    }
    // For invites the m.room.create event is usually absent from the stripped
    // invite state, so fall back to the well-known name we set on creation.
    final name = getState(EventTypes.RoomName)?.content.tryGet<String>('name');
    return name != null && name.startsWith('Stories from ');
  }

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

  /// The author/owner of this story room (its creator). For invites where the
  /// create event isn't available, the inviter is the owner.
  String? get storyAuthorId {
    final creator = getState(EventTypes.RoomCreate)?.senderId;
    if (creator != null) return creator;
    final me = client.userID;
    if (me != null) {
      final myMembership = getState(EventTypes.RoomMember, me);
      if (myMembership?.senderId != null) return myMembership!.senderId;
    }
    return null;
  }
}
