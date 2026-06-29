// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:async/async.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart' hide Result;
import 'package:url_launcher/url_launcher_string.dart';

import '../../utils/fluffy_share.dart';
import 'chat_list.dart';

class ClientChooserButton extends StatelessWidget {
  final ChatListController controller;

  const ClientChooserButton(this.controller, {super.key});

  List<PopupMenuEntry<Object>> _bundleMenuItems(BuildContext context) {
    final matrix = Matrix.of(context);
    final bundles = matrix.accountBundles.keys.toList()
      ..sort(
        (a, b) => a!.isValidMatrixId == b!.isValidMatrixId
            ? 0
            : a.isValidMatrixId && !b.isValidMatrixId
            ? -1
            : 1,
      );
    return <PopupMenuEntry<Object>>[
      PopupMenuItem(
        value: SettingsAction.newGroup,
        child: Row(
          children: [
            const Icon(Icons.group_add_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).createGroup),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.setStatus,
        child: Row(
          children: [
            const Icon(Icons.edit_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).setStatus),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.invite,
        child: Row(
          children: [
            Icon(Icons.adaptive.share_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).inviteContact),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.archive,
        child: Row(
          children: [
            const Icon(Icons.archive_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).archive),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.hidden,
        child: const Row(
          children: [
            Icon(Icons.visibility_off_outlined),
            SizedBox(width: 18),
            Text('Hidden chats'),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.settings,
        child: Row(
          children: [
            const Icon(Icons.settings_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).settings),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.supportTjena,
        child: const Row(
          children: [
            Icon(Icons.favorite, color: Colors.red),
            SizedBox(width: 18),
            Text('Support tjena!chat'),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.reportBug,
        child: const Row(
          children: [
            Icon(Icons.bug_report_outlined),
            SizedBox(width: 18),
            Text('Report a bug'),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.support,
        child: const Row(
          children: [
            Icon(Icons.source_outlined),
            SizedBox(width: 18),
            Text('Original source (FluffyChat)'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      for (final bundle in bundles) ...[
        if (matrix.accountBundles[bundle]!.length != 1 ||
            matrix.accountBundles[bundle]!.single!.userID != bundle)
          PopupMenuItem(
            value: null,
            child: Column(
              crossAxisAlignment: .start,
              mainAxisSize: .min,
              children: [
                Text(
                  bundle!,
                  style: TextStyle(
                    color: Theme.of(context).textTheme.titleMedium!.color,
                    fontSize: 14,
                  ),
                ),
                const Divider(height: 1),
              ],
            ),
          ),
        ...matrix.accountBundles[bundle]!
            .whereType<Client>()
            .where((client) => client.isLogged())
            .map(
              (client) => PopupMenuItem(
                value: client,
                child: FutureBuilder<Profile?>(
                  future: client.fetchOwnProfile(),
                  builder: (context, snapshot) {
                    final displayname =
                        snapshot.data?.displayName ?? client.userID!.localpart!;
                    return Row(
                      key: ValueKey('switch_account_$displayname'),
                      children: [
                        Avatar(
                          mxContent: snapshot.data?.avatarUrl,
                          name: displayname,
                          size: 32,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            displayname,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => controller.editBundlesForAccount(
                            client.userID,
                            bundle,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
      ],
      PopupMenuItem(
        value: SettingsAction.addAccount,
        child: Row(
          children: [
            const Icon(Icons.person_add_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).addAccount),
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final matrix = Matrix.of(context);
    final client = Result(() => matrix.client).asValue?.value;

    var clientCount = 0;
    matrix.accountBundles.forEach((key, value) => clientCount += value.length);
    return FutureBuilder<Profile>(
      future: client?.isLogged() == true ? client?.fetchOwnProfile() : null,
      builder: (context, snapshot) => Material(
        clipBehavior: Clip.hardEdge,
        borderRadius: BorderRadius.circular(99),
        color: Colors.transparent,
        child: PopupMenuButton<Object>(
          key: Key('accounts_and_settings_buttons'),
          tooltip: 'Accounts and settings',
          onSelected: (o) => _clientSelected(o, context),
          itemBuilder: _bundleMenuItems,
          child: Center(
            child: Avatar(
              mxContent: snapshot.data?.avatarUrl,
              name: snapshot.data?.displayName ?? client?.userID?.localpart,
              size: 32,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _clientSelected(Object object, BuildContext context) async {
    if (object is Client) {
      controller.setActiveClient(object);
    } else if (object is String) {
      controller.setActiveBundle(object);
    } else if (object is SettingsAction) {
      switch (object) {
        case SettingsAction.addAccount:
          if (!context.mounted) return;
          context.go('/rooms/settings/addaccount');
          break;
        case SettingsAction.newGroup:
          context.go('/rooms/newgroup');
          break;
        case SettingsAction.invite:
          FluffyShare.shareInviteLink(context);
          break;
        case SettingsAction.support:
          launchUrlString('https://fluffychat.im');
          break;
        case SettingsAction.supportTjena:
          launchUrlString('https://tjena.eu/support');
          break;
        case SettingsAction.reportBug:
          final result = await showFutureLoadingDialog(
            context: context,
            future: () => Matrix.of(context)
                .client
                .startDirectChat('@bugreport:tjena.eu'),
          );
          if (result.error == null && result.result != null && context.mounted) {
            context.go('/rooms/${result.result}');
          }
          break;
        case SettingsAction.settings:
          context.go('/rooms/settings');
          break;
        case SettingsAction.archive:
          context.go('/rooms/archive');
          break;
        case SettingsAction.hidden:
          context.go('/rooms/hidden');
          break;
        case SettingsAction.setStatus:
          controller.setStatus();
          break;
      }
    }
  }
}

enum SettingsAction {
  addAccount,
  newGroup,
  setStatus,
  invite,
  support,
  supportTjena,
  reportBug,
  settings,
  archive,
  hidden,
}
