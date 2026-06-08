// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/client_stories_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Settings for stories/status sharing: who receives my stories and who I
/// receive them from. Stories are restricted to my own homeserver.
class StoriesSettingsPage extends StatefulWidget {
  const StoriesSettingsPage({super.key});

  @override
  State<StoriesSettingsPage> createState() => _StoriesSettingsPageState();
}

class _StoriesSettingsPageState extends State<StoriesSettingsPage> {
  late bool _enabled = AppSettings.storiesEnabled.value;
  late String _sendScope = AppSettings.storiesSendScope.value;
  late String _receiveScope = AppSettings.storiesReceiveScope.value;
  late int _retentionHours = AppSettings.storiesRetentionHours.value;
  late final Set<String> _selected =
      Matrix.of(context).client.storiesSelectedRecipients.toSet();

  static const Map<String, int> _retentionOptions = {
    '6 hours': 6,
    '12 hours': 12,
    '24 hours': 24,
    '2 days': 48,
    '7 days': 168,
  };

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

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _enabled = enabled);
    await showFutureLoadingDialog(
      context: context,
      future: enabled ? client.enableStories : client.disableStories,
    );
  }

  Future<void> _setRetention(int hours) async {
    setState(() => _retentionHours = hours);
    await AppSettings.storiesRetentionHours.setItem(hours);
  }

  Future<void> _deleteMyStories() async {
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: 'Delete my stories',
      message: 'Remove all stories you have posted? This cannot be undone.',
      isDestructive: true,
    );
    if (confirmed != OkCancelResult.ok || !mounted) return;
    await showFutureLoadingDialog(
      context: context,
      future: client.deleteMyStories,
    );
  }

  Future<void> _cleanUpStoryRooms() async {
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: 'Clean up story rooms',
      message: 'Leave all story rooms (yours and ones shared with you), '
          'including old or stuck ones. You can re-enable stories afterwards '
          'to start fresh.',
      isDestructive: true,
    );
    if (confirmed != OkCancelResult.ok || !mounted) return;
    await showFutureLoadingDialog(
      context: context,
      future: client.leaveAllStoryRooms,
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
          SwitchListTile.adaptive(
            value: _enabled,
            onChanged: _setEnabled,
            title: const Text('Enable stories'),
            subtitle: const Text(
              'Turn on stories to set up your Stories space and start sharing '
              'and receiving stories with your contacts.',
            ),
          ),
          const Divider(),
          if (!_enabled)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Stories are turned off.',
                textAlign: TextAlign.center,
              ),
            ),
          if (_enabled) ...[
            ListTile(
              title: Text(
                'Receiving',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              subtitle: const Text(
                'Whose stories you see. Limited to your own server.',
              ),
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
            title: Text(
              'Story duration',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            subtitle: const Text('How long your stories stay visible.'),
          ),
          for (final entry in _retentionOptions.entries)
            RadioListTile<int>(
              title: Text(entry.key),
              value: entry.value,
              groupValue: _retentionHours,
              onChanged: (v) => _setRetention(v!),
            ),
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.delete_outline,
              color: theme.colorScheme.error,
            ),
              title: const Text('Delete my stories'),
              subtitle: const Text('Remove all stories you have posted.'),
              onTap: _deleteMyStories,
            ),
          ],
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.cleaning_services_outlined,
              color: theme.colorScheme.error,
            ),
            title: const Text('Clean up story rooms'),
            subtitle: const Text(
              'Leave all story rooms, including old or stuck ones. Use this if '
              'stories got into a broken state.',
            ),
            onTap: _cleanUpStoryRooms,
          ),
        ],
      ),
    );
  }
}
