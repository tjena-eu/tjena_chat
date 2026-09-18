// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_details/chat_details.dart';
import 'package:fluffychat/pages/chat_details/participant_list_item.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/media_auto_download.dart';
import 'package:fluffychat/utils/space_child_visibility.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/chat_settings_popup_menu.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../../utils/url_launcher.dart';
import '../../widgets/mxc_image_viewer.dart';
import '../../widgets/qr_code_viewer.dart';

class ChatDetailsView extends StatelessWidget {
  final ChatDetailsController controller;

  const ChatDetailsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final room = Matrix.of(context).client.getRoomById(controller.roomId!);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
        ),
      );
    }

    final directChatMatrixID = room.directChatMatrixID;
    final roomAvatar = room.avatar;
    final isWaRoom = WaMatrixBridge.instance.isWaRoom(room.id);

    return StreamBuilder(
      stream: room.client.onRoomState.stream.where(
        (update) => update.roomId == room.id,
      ),
      builder: (context, snapshot) {
        var members = room.getParticipants().toList()
          ..sort((b, a) => a.powerLevel.level.compareTo(b.powerLevel.level));
        members = members.take(10).toList();
        final actualMembersCount =
            (room.summary.mInvitedMemberCount ?? 0) +
            (room.summary.mJoinedMemberCount ?? 0);
        final canRequestMoreMembers = members.length < actualMembersCount;
        final iconColor = theme.textTheme.bodyLarge!.color;
        final displayname = room.getLocalizedDisplayname(
          MatrixLocals(L10n.of(context)),
        );
        return Scaffold(
          appBar: AppBar(
            leading:
                controller.widget.embeddedCloseButton ??
                const Center(child: BackButton()),
            elevation: theme.appBarTheme.elevation,
            actions: <Widget>[
              if (room.canonicalAlias.isNotEmpty)
                IconButton(
                  tooltip: L10n.of(context).share,
                  icon: const Icon(Icons.qr_code_rounded),
                  onPressed: () =>
                      showQrCodeViewer(context, room.canonicalAlias),
                )
              else if (directChatMatrixID != null)
                IconButton(
                  tooltip: L10n.of(context).share,
                  icon: const Icon(Icons.qr_code_rounded),
                  onPressed: () =>
                      showQrCodeViewer(context, directChatMatrixID),
                ),
              if (controller.widget.embeddedCloseButton == null)
                ChatSettingsPopupMenu(room, false),
            ],
            title: Text(L10n.of(context).chatDetails),
            backgroundColor: theme.appBarTheme.backgroundColor,
          ),
          body: MaxWidthBody(
            child: ListView.builder(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              itemCount: members.length + 1 + (canRequestMoreMembers ? 1 : 0),
              itemBuilder: (BuildContext context, int i) => i == 0
                  ? Column(
                      crossAxisAlignment: .stretch,
                      children: <Widget>[
                        Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(32.0),
                              child: Stack(
                                children: [
                                  Hero(
                                    tag:
                                        controller.widget.embeddedCloseButton !=
                                            null
                                        ? 'embedded_content_banner'
                                        : 'content_banner',
                                    child: Avatar(
                                      mxContent: room.avatar,
                                      name: displayname,
                                      size: Avatar.defaultSize * 2.5,
                                      onTap: isWaRoom || roomAvatar != null
                                          ? () {
                                              // Re-fetch just this chat's
                                              // photo from WhatsApp — fixes a
                                              // blank/black icon without the
                                              // heavy "WA sync" (name+photo+
                                              // history) flow.
                                              if (isWaRoom) {
                                                // ignore: unawaited_futures
                                                WaMatrixBridge.instance
                                                    .refreshRoom(room.id);
                                              }
                                              if (roomAvatar != null) {
                                                showDialog(
                                                  context: context,
                                                  builder: (_) =>
                                                      MxcImageViewer(
                                                        roomAvatar,
                                                      ),
                                                );
                                              }
                                            }
                                          : null,
                                    ),
                                  ),
                                  if (!room.isDirectChat &&
                                      room.canChangeStateEvent(
                                        EventTypes.RoomAvatar,
                                      ))
                                    Positioned(
                                      bottom: 0,
                                      right: 0,
                                      child: FloatingActionButton.small(
                                        onPressed: controller.setAvatarAction,
                                        heroTag: null,
                                        child: const Icon(
                                          Icons.camera_alt_outlined,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: .center,
                                crossAxisAlignment: .start,
                                children: [
                                  TextButton.icon(
                                    onPressed: () => room.isDirectChat
                                        ? null
                                        : room.canChangeStateEvent(
                                            EventTypes.RoomName,
                                          )
                                        ? controller.setDisplaynameAction()
                                        : FluffyShare.share(
                                            displayname,
                                            context,
                                            copyOnly: true,
                                          ),
                                    icon: Icon(
                                      room.isDirectChat
                                          ? Icons.chat_bubble_outline
                                          : room.canChangeStateEvent(
                                              EventTypes.RoomName,
                                            )
                                          ? Icons.edit_outlined
                                          : Icons.copy_outlined,
                                      size: 16,
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor:
                                          theme.colorScheme.onSurface,
                                      iconColor: theme.colorScheme.onSurface,
                                    ),
                                    label: Text(
                                      room.isDirectChat
                                          ? L10n.of(context).directChat
                                          : displayname,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => room.isDirectChat
                                        ? null
                                        : context.push(
                                            '/rooms/${controller.roomId}/details/members',
                                          ),
                                    icon: const Icon(
                                      Icons.group_outlined,
                                      size: 14,
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor:
                                          theme.colorScheme.secondary,
                                      iconColor: theme.colorScheme.secondary,
                                    ),
                                    label: Text(
                                      L10n.of(
                                        context,
                                      ).countParticipants(actualMembersCount),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      //    style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (room.canChangeStateEvent(EventTypes.RoomTopic) ||
                            room.topic.isNotEmpty) ...[
                          Divider(color: theme.dividerColor),
                          ListTile(
                            title: Text(
                              L10n.of(context).chatDescription,
                              style: TextStyle(
                                color: theme.colorScheme.secondary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            trailing:
                                room.canChangeStateEvent(EventTypes.RoomTopic)
                                ? IconButton(
                                    onPressed: controller.setTopicAction,
                                    tooltip: L10n.of(
                                      context,
                                    ).setChatDescription,
                                    icon: const Icon(Icons.edit_outlined),
                                  )
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: SelectableLinkify(
                              text: room.topic.isEmpty
                                  ? L10n.of(context).noChatDescriptionYet
                                  : room.topic,
                              textScaleFactor: MediaQuery.textScalerOf(
                                context,
                              ).scale(1),
                              options: const LinkifyOptions(humanize: false),
                              linkStyle: const TextStyle(
                                color: Colors.blueAccent,
                                decorationColor: Colors.blueAccent,
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                fontStyle: room.topic.isEmpty
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                                color: theme.textTheme.bodyMedium!.color,
                                decorationColor:
                                    theme.textTheme.bodyMedium!.color,
                              ),
                              onOpen: (url) =>
                                  UrlLauncher(context, url.url).launchUrl(),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        Divider(color: theme.dividerColor),
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.surfaceContainer,
                            foregroundColor: iconColor,
                            child: const Icon(Icons.photo_library_outlined),
                          ),
                          title: const Text('Media'),
                          trailing: const Icon(Icons.chevron_right_outlined),
                          onTap: () =>
                              context.go('/rooms/${room.id}/search?tab=1'),
                        ),
                        // Per-chat media auto-download. Lives here (not in the
                        // three-dot menu) so it sits next to the other
                        // per-chat settings.
                        Divider(color: theme.dividerColor),
                        _AutoDownloadTile(room: room, iconColor: iconColor),
                        // Spaces only: whether this space's chats also show up
                        // in the main chat list.
                        if (room.isSpace) ...[
                          Divider(color: theme.dividerColor),
                          _SpaceShowOutsideTile(
                            room: room,
                            iconColor: iconColor,
                          ),
                        ],
                        if (!room.isDirectChat) ...[
                          Divider(color: theme.dividerColor),
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.surfaceContainer,
                              foregroundColor: iconColor,
                              child: const Icon(
                                Icons.admin_panel_settings_outlined,
                              ),
                            ),
                            title: Text(L10n.of(context).accessAndVisibility),
                            subtitle: Text(
                              L10n.of(context).accessAndVisibilityDescription,
                            ),
                            onTap: () => context.push(
                              '/rooms/${room.id}/details/access',
                            ),
                            trailing: const Icon(Icons.chevron_right_outlined),
                          ),
                          ListTile(
                            title: Text(L10n.of(context).chatPermissions),
                            subtitle: Text(
                              L10n.of(context).whoCanPerformWhichAction,
                            ),
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.surfaceContainer,
                              foregroundColor: iconColor,
                              child: const Icon(Icons.tune_outlined),
                            ),
                            trailing: const Icon(Icons.chevron_right_outlined),
                            onTap: () => context.push(
                              '/rooms/${room.id}/details/permissions',
                            ),
                          ),
                        ],
                        Divider(color: theme.dividerColor),
                        ListTile(
                          title: Text(
                            L10n.of(
                              context,
                            ).countParticipants(actualMembersCount),
                            style: TextStyle(
                              color: theme.colorScheme.secondary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (!room.isDirectChat && room.canInvite)
                          ListTile(
                            title: Text(L10n.of(context).inviteContact),
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              foregroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                              radius: Avatar.defaultSize / 2,
                              child: const Icon(Icons.add_outlined),
                            ),
                            trailing: const Icon(Icons.chevron_right_outlined),
                            onTap: () => context.go('/rooms/${room.id}/invite'),
                          ),
                      ],
                    )
                  : i < members.length + 1
                  ? ParticipantListItem(members[i - 1])
                  : ListTile(
                      title: Text(
                        L10n.of(context).loadCountMoreParticipants(
                          (actualMembersCount - members.length),
                        ),
                      ),
                      leading: CircleAvatar(
                        backgroundColor: theme.scaffoldBackgroundColor,
                        child: const Icon(
                          Icons.group_outlined,
                          color: Colors.grey,
                        ),
                      ),
                      onTap: () => context.push(
                        '/rooms/${controller.roomId!}/details/members',
                      ),
                      trailing: const Icon(Icons.chevron_right_outlined),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// Per-chat switch for automatically downloading images and videos. Overrides
/// the global "Show thumbnails" setting for this one chat.
class _AutoDownloadTile extends StatefulWidget {
  final Room room;
  final Color? iconColor;

  const _AutoDownloadTile({required this.room, required this.iconColor});

  @override
  State<_AutoDownloadTile> createState() => _AutoDownloadTileState();
}

class _AutoDownloadTileState extends State<_AutoDownloadTile> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = MediaAutoDownload.enabledFor(widget.room.id);
    return SwitchListTile.adaptive(
      value: enabled,
      onChanged: (value) async {
        await MediaAutoDownload.setOverride(widget.room.id, value);
        if (mounted) setState(() {});
      },
      secondary: CircleAvatar(
        backgroundColor: theme.colorScheme.surfaceContainer,
        foregroundColor: widget.iconColor,
        child: Icon(
          enabled ? Icons.download_outlined : Icons.file_download_off_outlined,
        ),
      ),
      title: const Text('Auto-download media'),
      subtitle: Text(
        enabled
            ? 'Photos and videos load automatically in this chat.'
            : 'Photos and videos load only when you tap them.',
      ),
    );
  }
}

/// Spaces only: whether this space's chats also appear in the main chat list.
class _SpaceShowOutsideTile extends StatefulWidget {
  final Room room;
  final Color? iconColor;

  const _SpaceShowOutsideTile({required this.room, required this.iconColor});

  @override
  State<_SpaceShowOutsideTile> createState() => _SpaceShowOutsideTileState();
}

class _SpaceShowOutsideTileState extends State<_SpaceShowOutsideTile> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The stored flag is "hidden outside"; the switch reads better as the
    // positive "show in main list".
    final showOutside = !SpaceChildVisibility.instance.isHiddenOutside(
      widget.room.id,
    );
    return SwitchListTile.adaptive(
      value: showOutside,
      onChanged: (value) async {
        await SpaceChildVisibility.instance.setHiddenOutside(
          widget.room.id,
          !value,
        );
        if (mounted) setState(() {});
      },
      secondary: CircleAvatar(
        backgroundColor: theme.colorScheme.surfaceContainer,
        foregroundColor: widget.iconColor,
        child: Icon(
          showOutside ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
      ),
      title: const Text('Show chats in main list'),
      subtitle: Text(
        showOutside
            ? 'This space\'s chats also appear in your normal chat list.'
            : 'This space\'s chats only appear inside the space.',
      ),
    );
  }
}
