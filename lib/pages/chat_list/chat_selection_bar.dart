// SPDX-FileCopyrightText: 2026 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/utils/hidden_rooms.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

enum _More {
  pin,
  markRead,
  markUnread,
  join,
  lowPriority,
  addTag,
  removeTag,
  addToSpace,
  block,
  spacePin,
  spaceArchive,
  spaceRemove,
}

/// The app bar shown while chats are selected (long press). Every action
/// works on one or many chats.
class ChatSelectionBar extends StatelessWidget implements PreferredSizeWidget {
  final ChatListController controller;

  const ChatSelectionBar(this.controller, {super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rooms = controller.selectedRooms;
    final joined = rooms.where((r) => r.membership == Membership.join).toList();
    final invites = rooms
        .where((r) => r.membership == Membership.invite)
        .toList();
    final allMuted =
        joined.isNotEmpty &&
        joined.every((r) => r.pushRuleState != PushRuleState.notify);
    final allHidden = rooms.every((r) => HiddenRooms.instance.isHidden(r.id));
    final allFavourite =
        joined.isNotEmpty && joined.every((r) => r.isFavourite);
    final allUnread = joined.isNotEmpty && joined.every((r) => r.markedUnread);
    final allLowPriority =
        joined.isNotEmpty && joined.every((r) => r.isLowPriority);
    final space = controller.spaceViewKey.currentState;
    final inSpace = controller.activeSpaceId != null && space != null;
    final allSpacePinned = inSpace && rooms.every((r) => space.isPinned(r.id));
    final allSpaceArchived =
        inSpace && rooms.every((r) => space.isArchived(r.id));
    final activeTag = controller.activeTag;

    return AppBar(
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundColor: theme.colorScheme.onPrimaryContainer,
      leading: IconButton(
        tooltip: L10n.of(context).cancel,
        icon: const Icon(Icons.close),
        onPressed: controller.clearSelection,
      ),
      titleSpacing: 0,
      title: Text('${rooms.length}'),
      actions: [
        IconButton(
          tooltip: controller.allSelected ? 'Select none' : 'Select all',
          icon: Icon(
            controller.allSelected ? Icons.deselect : Icons.select_all,
          ),
          onPressed: controller.allSelected
              ? controller.clearSelection
              : controller.selectAll,
        ),
        if (joined.isNotEmpty)
          IconButton(
            tooltip: allMuted
                ? L10n.of(context).unmuteChat
                : L10n.of(context).muteChat,
            icon: Icon(
              allMuted
                  ? Icons.notifications_on_outlined
                  : Icons.notifications_off_outlined,
            ),
            onPressed: () => _run(
              context,
              joined,
              (r) => r.setPushRuleState(
                allMuted ? PushRuleState.notify : PushRuleState.mentionsOnly,
              ),
            ),
          ),
        IconButton(
          tooltip: allHidden ? 'Unhide' : 'Hide',
          icon: Icon(
            allHidden
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
          onPressed: () => _run(
            context,
            rooms,
            (r) => allHidden
                ? HiddenRooms.instance.unhide(r.id)
                : HiddenRooms.instance.hide(r.id),
          ),
        ),
        IconButton(
          tooltip: invites.length == rooms.length
              ? L10n.of(context).delete
              : L10n.of(context).leave,
          icon: const Icon(Icons.delete_outlined),
          onPressed: () => _leave(context, rooms),
        ),
        PopupMenuButton<_More>(
          onSelected: (a) => _onMore(context, a, rooms, joined, invites),
          itemBuilder: (context) => [
            if (joined.isNotEmpty && !allLowPriority)
              _item(
                _More.pin,
                allFavourite ? Icons.push_pin : Icons.push_pin_outlined,
                allFavourite ? L10n.of(context).unpin : L10n.of(context).pin,
              ),
            if (joined.isNotEmpty)
              allUnread
                  ? _item(
                      _More.markRead,
                      Icons.mark_as_unread,
                      L10n.of(context).markAsRead,
                    )
                  : _item(
                      _More.markUnread,
                      Icons.mark_as_unread_outlined,
                      L10n.of(context).markAsUnread,
                    ),
            if (invites.isNotEmpty)
              _item(_More.join, Icons.login_outlined, L10n.of(context).join),
            if (joined.isNotEmpty && !allFavourite)
              _item(
                _More.lowPriority,
                allLowPriority
                    ? Icons.low_priority
                    : Icons.low_priority_outlined,
                allLowPriority
                    ? L10n.of(context).unsetLowPriority
                    : L10n.of(context).setLowPriority,
              ),
            if (joined.isNotEmpty)
              activeTag == null
                  ? _item(
                      _More.addTag,
                      Icons.bookmark_add_outlined,
                      L10n.of(context).addTag,
                    )
                  : _item(
                      _More.removeTag,
                      Icons.bookmark_remove_outlined,
                      L10n.of(context).removeTag,
                    ),
            if (joined.isNotEmpty && _spacesFor(joined).isNotEmpty)
              _item(
                _More.addToSpace,
                Icons.group_work_outlined,
                L10n.of(context).addToSpace,
              ),
            if (inSpace) ...[
              _item(
                _More.spacePin,
                allSpacePinned ? Icons.push_pin : Icons.push_pin_outlined,
                allSpacePinned ? 'Unpin in space' : 'Pin in space',
              ),
              _item(
                _More.spaceArchive,
                allSpaceArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                allSpaceArchived ? 'Unarchive' : 'Archive',
              ),
              if (space.canRemoveChildren)
                _item(
                  _More.spaceRemove,
                  Icons.remove,
                  L10n.of(context).removeFromSpace,
                ),
            ],
            if (rooms.length == 1 && invites.length == 1)
              _item(_More.block, Icons.block_outlined, L10n.of(context).block),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<_More> _item(_More value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        child: Row(
          mainAxisSize: .min,
          children: [Icon(icon), const SizedBox(width: 12), Text(label)],
        ),
      );

  static List<Room> _spacesFor(List<Room> rooms) => rooms.first.client.rooms
      .where(
        (s) =>
            s.isSpace &&
            s.canChangeStateEvent(EventTypes.SpaceChild) &&
            rooms.any((r) => !s.spaceChildren.any((c) => c.roomId == r.id)),
      )
      .toList();

  /// Runs [op] on every room behind one loading dialog, then ends selection.
  Future<void> _run(
    BuildContext context,
    List<Room> rooms,
    Future<void> Function(Room room) op,
  ) async {
    if (rooms.isEmpty) return;
    await showFutureLoadingDialog(
      context: context,
      future: () async {
        for (final r in rooms) {
          await op(r);
        }
      },
    );
    controller.clearSelection();
  }

  Future<void> _leave(BuildContext context, List<Room> rooms) async {
    final onlyInvites = rooms.every((r) => r.membership == Membership.invite);
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: rooms.length == 1
          ? L10n.of(context).areYouSure
          : '${onlyInvites ? L10n.of(context).delete : L10n.of(context).leave} ${rooms.length} chats?',
      message: onlyInvites
          ? 'The invites are declined.'
          : L10n.of(context).archiveRoomDescription,
      okLabel: onlyInvites ? L10n.of(context).delete : L10n.of(context).leave,
      cancelLabel: L10n.of(context).cancel,
      isDestructive: true,
    );
    if (confirmed != OkCancelResult.ok || !context.mounted) return;
    await _run(context, rooms, (r) async {
      final wasInvite = r.membership == Membership.invite;
      await r.leave();
      // A declined invite has nothing to keep in the archive.
      if (wasInvite) {
        try {
          await r.forget();
        } catch (_) {}
      }
    });
  }

  Future<void> _onMore(
    BuildContext context,
    _More action,
    List<Room> rooms,
    List<Room> joined,
    List<Room> invites,
  ) async {
    final space = controller.spaceViewKey.currentState;
    switch (action) {
      case _More.pin:
        final pin = !joined.every((r) => r.isFavourite);
        return _run(context, joined, (r) => r.setFavourite(pin));
      case _More.markRead:
        return _run(context, joined, (r) => r.markUnread(false));
      case _More.markUnread:
        return _run(context, joined, (r) => r.markUnread(true));
      case _More.join:
        return _run(context, invites, (r) => r.join());
      case _More.lowPriority:
        final low = !joined.every((r) => r.isLowPriority);
        return _run(context, joined, (r) => r.setLowPriority(low));
      case _More.addTag:
        final tag = await _askTag(context, joined);
        if (tag == null || !context.mounted) return;
        return _run(context, joined, (r) => r.addTag('u.$tag'));
      case _More.removeTag:
        final tag = controller.activeTag;
        if (tag == null) return;
        return _run(context, joined, (r) => r.removeTag(tag));
      case _More.addToSpace:
        final spaces = _spacesFor(joined);
        final target = await showModalActionPopup(
          context: context,
          title: L10n.of(context).space,
          actions: spaces
              .map(
                (s) => AdaptiveModalAction(
                  value: s,
                  label: s.getLocalizedDisplayname(
                    MatrixLocals(L10n.of(context)),
                  ),
                ),
              )
              .toList(),
        );
        if (target == null || !context.mounted) return;
        return _run(context, joined, (r) => target.setSpaceChild(r.id));
      case _More.block:
        final room = invites.single;
        final inviteEvent = await room.requestUser(room.client.userID!);
        controller.clearSelection();
        if (!context.mounted) return;
        context.go(
          '/rooms/settings/security/ignorelist',
          extra: inviteEvent?.senderId,
        );
        return;
      case _More.spacePin:
        if (space == null) return;
        final pin = !rooms.every((r) => space.isPinned(r.id));
        await space.setPinned(rooms.map((r) => r.id), pin);
        controller.clearSelection();
        return;
      case _More.spaceArchive:
        if (space == null) return;
        final archive = !rooms.every((r) => space.isArchived(r.id));
        await space.setArchived(rooms.map((r) => r.id), archive);
        controller.clearSelection();
        return;
      case _More.spaceRemove:
        if (space == null) return;
        final consent = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).removeFromSpace,
          message: L10n.of(context).removeFromSpaceDescription,
        );
        if (consent != OkCancelResult.ok || !context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => space.removeFromSpace(rooms.map((r) => r.id)),
        );
        controller.clearSelection();
        return;
    }
  }

  Future<String?> _askTag(BuildContext context, List<Room> rooms) async {
    final existing = List.of(controller.roomTags.keys)
      ..removeWhere((t) => rooms.every((r) => r.tags.containsKey(t)));
    String? tag;
    if (existing.isNotEmpty) {
      tag = await showModalActionPopup<String?>(
        context: context,
        actions: [
          ...existing.map((t) {
            final display = t.replaceFirst('u.', '');
            return AdaptiveModalAction(label: display, value: display);
          }),
          AdaptiveModalAction(
            label: L10n.of(context).createNewTag,
            value: null,
          ),
        ],
      );
      if (!context.mounted) return null;
    }
    return tag ??
        await showTextInputDialog(
          context: context,
          title: L10n.of(context).addTag,
          hintText: L10n.of(context).tagName,
        );
  }
}
