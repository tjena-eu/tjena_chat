// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/pages/stories/add_story_sheet.dart';
import 'package:fluffychat/pages/stories/story_viewer.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/client_stories_extension.dart';
import 'package:fluffychat/utils/stream_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/hover_builder.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/adaptive_dialogs/user_dialog.dart';

/// Active story rooms keyed by their author's user id (most recent first is not
/// important here — we only need presence of a story).
Map<String, Room> _activeStoryRoomsByAuthor(Client client) {
  final map = <String, Room>{};
  for (final room in client.storiesRoomsWithActivePosts) {
    final author = room.storyAuthorId;
    if (author != null) map[author] = room;
  }
  return map;
}

class StatusMessageList extends StatelessWidget {
  final void Function() onStatusEdit;

  const StatusMessageList({required this.onStatusEdit, super.key});

  static const double height = 116;

  Future<void> _onStatusTab(
    BuildContext context,
    Profile profile,
    Room? storyRoom,
  ) async {
    final client = Matrix.of(context).client;
    final isOwn = profile.userId == client.userID;

    // Tapping someone else's avatar with an active story opens the viewer.
    if (!isOwn) {
      if (storyRoom != null) {
        await StoryViewer.show(context, storyRoom);
        return;
      }
      UserDialog.show(context: context, profile: profile);
      return;
    }

    // Own entry: offer to post / view a story or edit the status message.
    final action = await showModalActionPopup<String>(
      context: context,
      actions: [
        AdaptiveModalAction(
          value: 'add',
          label: 'Add to story',
          icon: const Icon(Icons.add_a_photo_outlined),
        ),
        if (storyRoom != null)
          AdaptiveModalAction(
            value: 'view',
            label: 'View my story',
            icon: const Icon(Icons.visibility_outlined),
          ),
        AdaptiveModalAction(
          value: 'status',
          label: 'Set status',
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'add':
        await showAddStorySheet(context);
        break;
      case 'view':
        if (storyRoom != null) await StoryViewer.show(context, storyRoom);
        break;
      case 'status':
        onStatusEdit();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final storyRooms = _activeStoryRoomsByAuthor(client);
    // Show story authors in the row too, even if they have no live presence.
    final userIds = {...client.interestingPresences, ...storyRooms.keys};

    return StreamBuilder(
      stream: client.onSync.stream.rateLimit(const Duration(seconds: 3)),
      builder: (context, snapshot) {
        return AnimatedSize(
          duration: FluffyThemes.animationDuration,
          curve: Curves.easeInOut,
          child: FutureBuilder(
            initialData: userIds
                // ignore: deprecated_member_use
                .map((userId) => client.presences[userId])
                .whereType<CachedPresence>(),
            future: Future.wait(
              userIds.map(
                (userId) => client.fetchCurrentPresence(
                  userId,
                  fetchOnlyFromCached: true,
                ),
              ),
            ),
            builder: (context, snapshot) {
              final presences = snapshot.data
                  ?.where(
                    (p) =>
                        p.userid == client.userID ||
                        storyRooms.containsKey(p.userid) ||
                        isInterestingPresence(p),
                  )
                  .toList();

              // Always show at least our own entry so a story can be added.
              if (presences == null || presences.isEmpty) {
                return const SizedBox.shrink();
              }

              presences.sort((a, b) {
                // Make sure own entry is at the first position:
                if (a.userid == client.userID) return -1;
                if (b.userid == client.userID) return 1;
                // Users with an active story first:
                final aStory = storyRooms.containsKey(a.userid);
                final bStory = storyRooms.containsKey(b.userid);
                if (aStory && !bStory) return -1;
                if (!aStory && bStory) return 1;
                // Sort presences with statusMsg first:
                if (a.statusMsg != null && b.statusMsg == null) return -1;
                if (a.statusMsg == null && b.statusMsg != null) return 1;
                // Sort by creation date:
                return b.sortOrderDateTime.compareTo(a.sortOrderDateTime);
              });

              return SizedBox(
                height: StatusMessageList.height,
                child: ListView.builder(
                  padding: const EdgeInsets.only(
                    left: 8.0,
                    right: 8.0,
                    top: 8.0,
                    bottom: 6.0,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: presences.length,
                  itemBuilder: (context, i) {
                    final storyRoom = storyRooms[presences[i].userid];
                    return PresenceAvatar(
                      presence: presences[i],
                      height: StatusMessageList.height,
                      hasStory: storyRoom != null,
                      onTap: (profile) =>
                          _onStatusTab(context, profile, storyRoom),
                    );
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class PresenceAvatar extends StatelessWidget {
  final CachedPresence presence;
  final double height;
  final bool hasStory;
  final void Function(Profile) onTap;

  const PresenceAvatar({
    required this.presence,
    required this.height,
    required this.onTap,
    this.hasStory = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final avatarSize = height - 16 - 16 - 6;
    final client = Matrix.of(context).client;
    return FutureBuilder<Profile>(
      future: client.getProfileFromUserId(presence.userid),
      builder: (context, snapshot) {
        final theme = Theme.of(context);

        final profile = snapshot.data;
        final displayName =
            profile?.displayName ??
            presence.userid.localpart ??
            presence.userid;
        final statusMsg = presence.statusMsg;

        const statusMsgBubbleElevation = 6.0;
        final statusMsgBubbleShadowColor = theme.colorScheme.surfaceBright;
        final statusMsgBubbleColor = Colors.white.withAlpha(212);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: SizedBox(
            width: avatarSize,
            child: Column(
              children: [
                HoverBuilder(
                  builder: (context, hovered) {
                    return AnimatedScale(
                      scale: hovered ? 1.15 : 1.0,
                      duration: FluffyThemes.animationDuration,
                      curve: FluffyThemes.animationCurve,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(avatarSize),
                        onTap: profile == null ? null : () => onTap(profile),
                        child: Material(
                          borderRadius: BorderRadius.circular(avatarSize),
                          child: Stack(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  // A vibrant ring marks an active story;
                                  // otherwise fall back to the presence colour.
                                  gradient: hasStory
                                      ? const LinearGradient(
                                          colors: [
                                            Color(0xFFF58529),
                                            Color(0xFFDD2A7B),
                                            Color(0xFF8134AF),
                                          ],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        )
                                      : presence.gradient,
                                  borderRadius: BorderRadius.circular(
                                    avatarSize,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Container(
                                  height: avatarSize - 6,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface,
                                    borderRadius: BorderRadius.circular(
                                      avatarSize,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(3.0),
                                  child: Avatar(
                                    name: displayName,
                                    mxContent: profile?.avatarUrl,
                                    size: avatarSize - 12,
                                  ),
                                ),
                              ),
                              if (presence.userid == client.userID)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: FloatingActionButton.small(
                                      heroTag: null,
                                      onPressed: () => onTap(
                                        profile ??
                                            Profile(userId: presence.userid),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(
                                        Icons.add_outlined,
                                        size: 16,
                                      ),
                                    ),
                                  ),
                                ),
                              if (statusMsg != null) ...[
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  right: 0,
                                  child: Column(
                                    spacing: 2,
                                    crossAxisAlignment: .start,
                                    mainAxisSize: .min,
                                    children: [
                                      Material(
                                        elevation: statusMsgBubbleElevation,
                                        shadowColor: statusMsgBubbleShadowColor,
                                        borderRadius: BorderRadius.circular(
                                          AppConfig.borderRadius / 2,
                                        ),
                                        color: statusMsgBubbleColor,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 2.0,
                                            horizontal: 4.0,
                                          ),
                                          child: Text(
                                            statusMsg,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontSize: 9,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 8.0,
                                        ),
                                        child: Material(
                                          color: statusMsgBubbleColor,
                                          elevation: statusMsgBubbleElevation,
                                          shadowColor:
                                              statusMsgBubbleShadowColor,
                                          borderRadius: BorderRadius.circular(
                                            AppConfig.borderRadius,
                                          ),
                                          child: const SizedBox.square(
                                            dimension: 8,
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 13.0,
                                        ),
                                        child: Material(
                                          color: statusMsgBubbleColor,
                                          elevation: statusMsgBubbleElevation,
                                          shadowColor:
                                              statusMsgBubbleShadowColor,
                                          borderRadius: BorderRadius.circular(
                                            AppConfig.borderRadius,
                                          ),
                                          child: const SizedBox.square(
                                            dimension: 5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text(
                    displayName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

extension on Client {
  Set<String> get interestingPresences {
    final allHeroes = rooms
        .map((room) => room.summary.mHeroes)
        .fold(
          <String>{},
          (previousValue, element) => previousValue..addAll(element ?? {}),
        );
    allHeroes.add(userID!);
    return allHeroes;
  }
}

bool isInterestingPresence(CachedPresence presence) =>
    !presence.presence.isOffline || (presence.statusMsg?.isNotEmpty ?? false);

extension on CachedPresence {
  DateTime get sortOrderDateTime =>
      lastActiveTimestamp ??
      (currentlyActive == true
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(0));

  LinearGradient get gradient => presence.isOnline == true
      ? LinearGradient(
          colors: [Colors.green, Colors.green.shade200, Colors.green.shade900],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        )
      : presence.isUnavailable
      ? LinearGradient(
          colors: [
            Colors.yellow,
            Colors.yellow.shade200,
            Colors.yellow.shade900,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        )
      : LinearGradient(
          colors: [Colors.grey, Colors.grey.shade200, Colors.grey.shade900],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
}
