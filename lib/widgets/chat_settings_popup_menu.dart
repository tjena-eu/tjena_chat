// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'matrix.dart';

enum ChatPopupMenuActions {
  details,
  mute,
  unmute,
  encryption,
  emote,
  leave,
  search,
  media,
  syncWaRoom,
  loadWaBackfill,
}

class ChatSettingsPopupMenu extends StatefulWidget {
  final Room room;
  final bool displayChatDetails;

  const ChatSettingsPopupMenu(this.room, this.displayChatDetails, {super.key});

  @override
  ChatSettingsPopupMenuState createState() => ChatSettingsPopupMenuState();
}

class ChatSettingsPopupMenuState extends State<ChatSettingsPopupMenu> {
  StreamSubscription? notificationChangeSub;

  @override
  void dispose() {
    notificationChangeSub?.cancel();
    super.dispose();
  }

  void goToEmoteSettings() =>
      context.push('/rooms/${widget.room.id}/details/emotes');

  @override
  Widget build(BuildContext context) {
    notificationChangeSub ??= Matrix.of(context).client.onSync.stream
        .where(
          (syncUpdate) =>
              syncUpdate.accountData?.any(
                (accountData) => accountData.type == 'm.push_rules',
              ) ??
              false,
        )
        .listen((u) => setState(() {}));
    return Stack(
      alignment: Alignment.center,
      children: [
        const SizedBox.shrink(),
        PopupMenuButton<ChatPopupMenuActions>(
          useRootNavigator: true,
          onSelected: (choice) async {
            switch (choice) {
              case ChatPopupMenuActions.leave:
                final l10n = L10n.of(context);
                final router = GoRouter.of(context);
                final confirmed = await showOkCancelAlertDialog(
                  context: context,
                  title: l10n.areYouSure,
                  message: l10n.archiveRoomDescription,
                  okLabel: l10n.leave,
                  cancelLabel: l10n.cancel,
                  isDestructive: true,
                );
                if (confirmed != OkCancelResult.ok) return;
                if (!context.mounted) return;
                final result = await showFutureLoadingDialog(
                  context: context,
                  future: () => widget.room.leave(),
                );
                if (result.error == null) {
                  router.go('/rooms');
                }

                break;
              case ChatPopupMenuActions.mute:
                await showFutureLoadingDialog(
                  context: context,
                  future: () =>
                      widget.room.setPushRuleState(PushRuleState.mentionsOnly),
                );
                break;
              case ChatPopupMenuActions.unmute:
                await showFutureLoadingDialog(
                  context: context,
                  future: () =>
                      widget.room.setPushRuleState(PushRuleState.notify),
                );
                break;
              case ChatPopupMenuActions.details:
                _showChatDetails();
                break;
              case ChatPopupMenuActions.search:
                context.go('/rooms/${widget.room.id}/search');
                break;
              case ChatPopupMenuActions.media:
                context.go('/rooms/${widget.room.id}/search?tab=1');
                break;
              case ChatPopupMenuActions.emote:
                goToEmoteSettings();
              case ChatPopupMenuActions.encryption:
                context.go('/rooms/${widget.room.id}/encryption');
                break;
              case ChatPopupMenuActions.syncWaRoom:
                await _waSync();
                break;
              case ChatPopupMenuActions.loadWaBackfill:
                await _loadWaBackfill();
                break;
            }
          },
          itemBuilder: (BuildContext context) => [
            if (widget.displayChatDetails)
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.details,
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).chatDetails),
                  ],
                ),
              ),
            if (widget.room.pushRuleState == PushRuleState.notify)
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.mute,
                child: Row(
                  children: [
                    const Icon(Icons.notifications_off_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).muteChat),
                  ],
                ),
              )
            else
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.unmute,
                child: Row(
                  children: [
                    const Icon(Icons.notifications_on_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).unmuteChat),
                  ],
                ),
              ),
            PopupMenuItem<ChatPopupMenuActions>(
              value: ChatPopupMenuActions.search,
              child: Row(
                children: [
                  const Icon(Icons.search_outlined),
                  const SizedBox(width: 12),
                  Text(L10n.of(context).search),
                ],
              ),
            ),
            PopupMenuItem<ChatPopupMenuActions>(
              value: ChatPopupMenuActions.media,
              child: const Row(
                children: [
                  Icon(Icons.photo_library_outlined),
                  SizedBox(width: 12),
                  Text('Media'),
                ],
              ),
            ),
            PopupMenuItem<ChatPopupMenuActions>(
              value: ChatPopupMenuActions.encryption,
              child: Row(
                children: [
                  const Icon(Icons.lock_outlined),
                  const SizedBox(width: 12),
                  Text(L10n.of(context).encryption),
                ],
              ),
            ),
            PopupMenuItem<ChatPopupMenuActions>(
              value: ChatPopupMenuActions.emote,
              child: Row(
                children: [
                  const Icon(Icons.emoji_emotions_outlined),
                  const SizedBox(width: 12),
                  Text(L10n.of(context).emoteSettings),
                ],
              ),
            ),
            if (PlatformInfos.isAndroid &&
                WaMatrixBridge.instance.isWaRoom(widget.room.id))
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.syncWaRoom,
                child: const Row(
                  children: [
                    Icon(Icons.sync_outlined),
                    SizedBox(width: 12),
                    Text('WA sync'),
                  ],
                ),
              ),
            if (PlatformInfos.isAndroid &&
                WaMatrixBridge.instance.isWaRoom(widget.room.id))
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.loadWaBackfill,
                child: const Row(
                  children: [
                    Icon(Icons.history_outlined),
                    SizedBox(width: 12),
                    Text('Load history'),
                  ],
                ),
              ),
            PopupMenuItem<ChatPopupMenuActions>(
              value: ChatPopupMenuActions.leave,
              child: Row(
                children: [
                  const Icon(Icons.delete_outlined),
                  const SizedBox(width: 12),
                  Text(L10n.of(context).leave),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Prompts for a number of days of history. Returns null if cancelled.
  Future<int?> _askBackfillDays(String title, String actionLabel) async {
    final controller = TextEditingController(text: '7');
    return showDialog<int>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('How many days of history should be loaded?'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Days',
                border: OutlineInputBorder(),
                suffixText: 'days',
              ),
              onSubmitted: (v) =>
                  Navigator.of(context).pop(int.tryParse(v.trim())),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(controller.text.trim())),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  /// The per-chat "WA sync": refresh name + photo (+ contact names), wipe the
  /// local history for this chat and cleanly re-pull the requested days.
  Future<void> _waSync() async {
    final days = await _askBackfillDays('WA sync', 'Sync');
    if (days == null || days < 1 || !mounted) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () =>
          WaMatrixBridge.instance.resyncRoom(widget.room.id, days),
    );
    if (result.error == null && mounted) {
      final count = result.result ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(count > 0
              ? 'Synced name & photo · loaded $count message(s) · fetching older from WhatsApp…'
              : 'Synced name & photo · no local history · fetching from WhatsApp…'),
        ),
      );
    }
  }

  Future<void> _loadWaBackfill() async {
    final days = await _askBackfillDays('Load history', 'Load');
    if (days == null || days < 1 || !mounted) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => WaMatrixBridge.instance.requestBackfill(widget.room.id, days),
    );
    if (result.error == null && mounted) {
      final count = result.result ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(count > 0
              ? 'Loaded $count message(s) · fetching older from WhatsApp…'
              : 'No local history · fetching from WhatsApp…'),
        ),
      );
    }
  }

  void _showChatDetails() {
    if (GoRouterState.of(context).uri.path.endsWith('/details')) {
      context.go('/rooms/${widget.room.id}');
    } else {
      context.go('/rooms/${widget.room.id}/details');
    }
  }
}
