// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_details/chat_details.dart';
import 'package:fluffychat/pages/chat_details/participant_list_item.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/media_auto_download.dart';
import 'package:fluffychat/utils/space_child_visibility.dart';
import 'package:fluffychat/utils/verified_room_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/chat_settings_popup_menu.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
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
                        Center(
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
                                  onTap: roomAvatar != null
                                      ? () => showDialog(
                                          context: context,
                                          builder: (_) =>
                                              MxcImageViewer(roomAvatar),
                                        )
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
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Center(
                            child: TextButton.icon(
                              onPressed:
                                  room.isDirectChat ||
                                      !room.canChangeStateEvent(
                                        EventTypes.RoomName,
                                      )
                                  ? null
                                  : controller.setDisplaynameAction,
                              icon:
                                  room.isDirectChat ||
                                      !room.canChangeStateEvent(
                                        EventTypes.RoomName,
                                      )
                                  ? null
                                  : Icon(Icons.edit_outlined, size: 16),

                              style: TextButton.styleFrom(
                                foregroundColor: theme.colorScheme.onSurface,
                                iconColor: theme.colorScheme.onSurface,
                                disabledForegroundColor:
                                    theme.colorScheme.onSurface,
                              ),
                              label: Row(
                                mainAxisSize: .min,
                                spacing: 4,
                                children: [
                                  if (room.allUsersVerified)
                                    Icon(
                                      Icons.verified,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      size: 18,
                                    ),
                                  Text(
                                    displayname,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        StreamBuilder(
                          stream: room.client.onSync.stream.where(
                            (s) =>
                                s.accountData?.any(
                                  (data) => data.type == 'm.push_rules',
                                ) ??
                                false,
                          ),
                          builder: (context, _) => Wrap(
                            alignment: .center,
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              _MainChatDetailsButton(
                                onPressed: () =>
                                    context.go('/rooms/${room.id}/search'),
                                label: L10n.of(context).search,
                                icon: Icons.search,
                              ),
                              _MainChatDetailsButton(
                                onPressed: () => context.push(
                                  '/rooms/${room.id}/details/emotes',
                                ),
                                label: L10n.of(context).stickers,
                                icon: Icons.emoji_emotions_outlined,
                              ),
                              if (room.pushRuleState == PushRuleState.notify)
                                _MainChatDetailsButton(
                                  onPressed: () => showFutureLoadingDialog(
                                    context: context,
                                    future: () => room.setPushRuleState(
                                      PushRuleState.mentionsOnly,
                                    ),
                                  ),
                                  label: L10n.of(context).mute,
                                  icon: Icons.notifications_on_outlined,
                                )
                              else
                                _MainChatDetailsButton(
                                  onPressed: () => showFutureLoadingDialog(
                                    context: context,
                                    future: () => room.setPushRuleState(
                                      PushRuleState.notify,
                                    ),
                                  ),
                                  label: L10n.of(context).unmuteChat,
                                  icon: Icons.notifications_off_outlined,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (room.canChangeStateEvent(EventTypes.RoomTopic) ||
                            room.topic.isNotEmpty) ...[
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
                          trailing: !room.isDirectChat && room.canInvite
                              ? TextButton.icon(
                                  icon: Icon(Icons.add),
                                  label: Text(L10n.of(context).invite),
                                  onPressed: () =>
                                      context.go('/rooms/${room.id}/invite'),
                                )
                              : null,
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
          showOutside
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
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

class _MainChatDetailsButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;
  final IconData icon;

  const _MainChatDetailsButton({
    required this.onPressed,
    required this.label,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppConfig.borderRadius),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppConfig.borderRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: .center,
            mainAxisSize: .min,
            children: [
              Icon(icon, color: theme.colorScheme.secondary),
              SizedBox(
                width: 64,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: .ellipsis,
                  textAlign: .center,
                  style: TextStyle(color: theme.colorScheme.secondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
