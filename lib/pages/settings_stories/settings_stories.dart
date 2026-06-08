// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/client_stories_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';

/// Settings for stories/status sharing: who receives my stories and who I
/// receive them from. Stories are restricted to my own homeserver.
class StoriesSettingsPage extends StatefulWidget {
  const StoriesSettingsPage({super.key});

  @override
  State<StoriesSettingsPage> createState() => _StoriesSettingsPageState();
}

class _StoriesSettingsPageState extends State<StoriesSettingsPage> {
  late String _sendScope = AppSettings.storiesSendScope.value;
  late String _receiveScope = AppSettings.storiesReceiveScope.value;
  late Set<String> _selected =
      Matrix.of(context).client.storiesSelectedRecipients.toSet();

  Client get client => Matrix.of(context).client;

  Future<void> _applyChanges() async {
    await showFutureLoadingDialog(
      context: context,
      future: () async {
        await client.setStoriesSelectedRecipients(_selected.toList());
        await client.syncMyStoryRoomInvites();
        await client.applyStoriesReceivePolicy();
      },
    );
  }

  Future<void> _setSendScope(String scope) async {
    setState(() => _sendScope = scope);
    await AppSettings.storiesSendScope.setItem(scope);
    await _applyChanges();
  }

  Future<void> _setReceiveScope(String scope) async {
    setState(() => _receiveScope = scope);
    await AppSettings.storiesReceiveScope.setItem(scope);
    await _applyChanges();
  }

  Future<void> _toggleRecipient(String userId, bool selected) async {
    setState(() {
      if (selected) {
        _selected.add(userId);
      } else {
        _selected.remove(userId);
      }
    });
    await _applyChanges();
  }

  Future<void> _resetSharing() async {
    final room = client.myStoriesRoom;
    if (room == null) return;
    await showFutureLoadingDialog(
      context: context,
      future: room.leave,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contacts = client.storyContacts;

    return Scaffold(
      appBar: AppBar(title: const Text('Stories')),
      body: ListView(
        children: [
          ListTile(
            title: Text(
              'Receiving',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            subtitle: const Text('Whose stories you see. Limited to your own server.'),
          ),
          RadioListTile<String>(
            title: const Text('Receive from everyone (same server)'),
            value: 'all',
            groupValue: _receiveScope,
            onChanged: (v) => _setReceiveScope(v!),
          ),
          RadioListTile<String>(
            title: const Text('Receive none'),
            value: 'none',
            groupValue: _receiveScope,
            onChanged: (v) => _setReceiveScope(v!),
          ),
          const Divider(),
          ListTile(
            title: Text(
              'Sharing',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            subtitle: const Text('Who can see the stories you post.'),
          ),
          RadioListTile<String>(
            title: const Text('Don\'t share'),
            value: 'none',
            groupValue: _sendScope,
            onChanged: (v) => _setSendScope(v!),
          ),
          RadioListTile<String>(
            title: const Text('All my contacts (same server)'),
            value: 'all',
            groupValue: _sendScope,
            onChanged: (v) => _setSendScope(v!),
          ),
          RadioListTile<String>(
            title: const Text('Only selected contacts'),
            value: 'selected',
            groupValue: _sendScope,
            onChanged: (v) => _setSendScope(v!),
          ),
          if (_sendScope == 'selected') ...[
            const Divider(),
            ListTile(
              title: Text(
                'Selected contacts',
                style: theme.textTheme.titleSmall,
              ),
              subtitle: contacts.isEmpty
                  ? const Text('No contacts on your server yet.')
                  : null,
            ),
            for (final user in contacts)
              CheckboxListTile(
                value: _selected.contains(user.id),
                onChanged: (v) => _toggleRecipient(user.id, v ?? false),
                secondary: Avatar(
                  name: user.calcDisplayname(),
                  mxContent: user.avatarUrl,
                  size: 32,
                ),
                title: Text(user.calcDisplayname()),
                subtitle: Text(
                  user.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.refresh,
              color: theme.colorScheme.error,
            ),
            title: const Text('Reset story sharing'),
            subtitle: const Text(
              'Leave and recreate your story room. Use this if sharing got '
              'stuck after leaving or missing an invite.',
            ),
            onTap: _resetSharing,
          ),
        ],
      ),
    );
  }
}
