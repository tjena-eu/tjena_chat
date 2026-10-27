// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:fluffychat/utils/personal_bridge.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class SettingsDebug extends StatefulWidget {
  const SettingsDebug({super.key});

  @override
  State<SettingsDebug> createState() => _SettingsDebugState();
}

class _CallInfo {
  final List<String> liveKitUrls;
  final Map<String, bool> reachable;
  final String? error;
  const _CallInfo(this.liveKitUrls, this.reachable, [this.error]);
}

class _SettingsDebugState extends State<SettingsDebug> {
  bool _busy = false;
  List<String>? _bridgeLog;
  Future<_CallInfo>? _callInfo;

  @override
  void initState() {
    super.initState();
    _callInfo = _loadCallInfo();
  }

  /// Which call system the chat call button uses. [refresh] re-reads the
  /// server's .well-known now and updates the app's cached copy.
  Future<_CallInfo> _loadCallInfo({bool refresh = false}) async {
    final client = Matrix.of(context).client;
    try {
      final urls = refresh
          ? await client.getLiveKitServiceUrls(
              wellKnownCacheLifetime: const Duration(seconds: 1),
            )
          : await client.getLiveKitServiceUrls();
      final reachable = <String, bool>{};
      for (final url in urls) {
        try {
          final resp = await client.httpClient
              .get(Uri.parse('${url.replaceAll(RegExp(r'/+$'), '')}/healthz'))
              .timeout(const Duration(seconds: 5));
          reachable[url] = resp.statusCode == 200;
        } catch (_) {
          reachable[url] = false;
        }
      }
      return _CallInfo(urls, reachable);
    } catch (e) {
      return _CallInfo(const [], const {}, e.toString());
    }
  }

  Widget _callsCard(ThemeData theme) => FutureBuilder<_CallInfo>(
    future: _callInfo,
    builder: (context, snap) {
      final info = snap.data;
      final legacyOn = AppSettings.experimentalVoip.value;
      final String mode;
      final IconData icon;
      if (info == null) {
        mode = 'Checking…';
        icon = Icons.hourglass_empty;
      } else if (info.liveKitUrls.isNotEmpty) {
        mode = 'LiveKit (MatrixRTC)';
        icon = Icons.groups_outlined;
      } else if (legacyOn) {
        mode = 'Old 1:1 calls';
        icon = Icons.call_outlined;
      } else {
        mode = 'Off (no LiveKit, old calls disabled)';
        icon = Icons.phone_disabled_outlined;
      }
      final lkText = info == null
          ? '…'
          : info.error != null
          ? 'Check failed: ${info.error}'
          : info.liveKitUrls.isEmpty
          ? 'Not advertised by the server'
          : info.liveKitUrls
                .map(
                  (u) =>
                      '$u (${info.reachable[u] == true ? 'reachable' : 'NOT reachable'})',
                )
                .join('\n');
      return Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            ListTile(
              leading: Icon(icon),
              title: Text('Call button uses: $mode'),
              subtitle: const Text(
                'Matrix chats. Decided by the server (.well-known), '
                're-read every hour.',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('LiveKit service'),
              subtitle: Text(lkText),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.call_received_outlined),
              title: Text('Old 1:1 calls: ${legacyOn ? 'on' : 'off'}'),
              subtitle: const Text(
                'Incoming old-style calls from older tjena versions '
                'still ring.',
              ),
            ),
            const Divider(height: 1),
            const ListTile(
              leading: Icon(Icons.chat_outlined),
              title: Text('WhatsApp calls: through your own bridge'),
              subtitle: Text('Not affected by the LiveKit switch.'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Check again now'),
              subtitle: const Text(
                'Re-reads the server setting (applies to chats opened '
                'afterwards).',
              ),
              onTap: () =>
                  setState(() => _callInfo = _loadCallInfo(refresh: true)),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _deleteRooms(List<Room> rooms) async {
    if (rooms.isEmpty) return;
    final client = Matrix.of(context).client;
    setState(() => _busy = true);
    for (final room in rooms) {
      await _deleteOne(client, room);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _deleteOne(Client client, Room room) async {
    try {
      // Leaving an invite declines it.
      if (room.membership != Membership.leave) await room.leave();
    } catch (_) {}
    try {
      await room.forget();
    } catch (_) {}
  }

  Future<void> _deleteAllDMs() async {
    final client = Matrix.of(context).client;
    final dms = client.rooms
        .where((r) => !r.isSpace && r.isDirectChat)
        .toList();
    final unique = {for (final r in dms) r.id: r}.values.toList();
    final confirmed = await _confirm(
      'Delete all direct chats (${unique.length})?',
      'This removes ${unique.length} direct chats from this device. Matrix rooms will be left on the server.',
    );
    if (!confirmed) return;
    await _deleteRooms(unique);
  }

  Future<void> _deleteAllGroups() async {
    final client = Matrix.of(context).client;
    final groups = client.rooms
        .where((r) => !r.isSpace && !r.isDirectChat)
        .toList();
    final confirmed = await _confirm(
      'Delete all group chats (${groups.length})?',
      'This removes ${groups.length} group chats from this device. Matrix rooms will be left on the server.',
    );
    if (!confirmed) return;
    await _deleteRooms(groups);
  }

  Future<void> _deleteEverything() async {
    final client = Matrix.of(context).client;
    final all = client.rooms
        .where((r) => r.membership != Membership.leave)
        .toList();
    final invites = all.where((r) => r.membership == Membership.invite).length;
    final confirmed = await _confirm(
      'Delete everything (${all.length})?',
      'Leaves and forgets every chat, group and space, and declines '
          '$invites invites. Bridged chats (WhatsApp) come back when new '
          'messages arrive while the bridge is still linked.',
    );
    if (!confirmed) return;
    // Rooms before spaces, so space children aren't re-listed in between.
    all.sort((a, b) => (a.isSpace ? 1 : 0) - (b.isSpace ? 1 : 0));
    await _deleteRooms(all);
  }

  Future<void> _declineInvites() async {
    final client = Matrix.of(context).client;
    final invites = client.rooms
        .where((r) => r.membership == Membership.invite)
        .toList();
    if (invites.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No open invites.')));
      return;
    }
    final confirmed = await _confirm(
      'Decline all invites (${invites.length})?',
      'Every open invite to a chat, group or space is declined.',
      action: 'Decline',
    );
    if (!confirmed) return;
    await _deleteRooms(invites);
  }

  /// Bridge bots this account has chats from (plus the configured ones).
  Map<String, int> _bridgeBots(Client client) {
    final cfg = WhatsAppBridgeConfig.of(client);
    final bots = <String>{
      WhatsAppBridgeConfig.serverBot(client),
      if (cfg.ownBot != null) cfg.ownBot!,
      for (final r in client.rooms) ?RoomBridgeInfo.of(r)?.bridgeBot,
    };
    return {for (final b in bots) b: BridgeCleanup.roomsOf(client, b).length};
  }

  Future<void> _cleanupBridge(String bot) async {
    final client = Matrix.of(context).client;
    final cfg = WhatsAppBridgeConfig.of(client);
    final own = cfg.ownBot == bot;
    final count = BridgeCleanup.roomsOf(client, bot).length;
    var logout = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('Remove bridge $bot?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${own ? 'Your own bridge is removed from the tjena server and the app switches back to the server bridge. ' : ''}'
                '$count chats, spaces and invites from this bridge are left '
                'and forgotten, including the bot chat.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: logout,
                onChanged: (v) => setDialog(() => logout = v ?? true),
                title: const Text('Log WhatsApp out first'),
                subtitle: const Text(
                  'Turn off if the bridge is broken or offline (saves '
                  'waiting for it).',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final lines = <String>[];
    setState(() {
      _busy = true;
      _bridgeLog = lines;
    });
    await BridgeCleanup.run(
      client,
      bot: bot,
      own: own,
      logout: logout,
      log: (l) {
        if (mounted) setState(() => lines.add(l));
      },
    );
    if (mounted) setState(() => _busy = false);
  }

  Widget _bridgeCard() {
    final client = Matrix.of(context).client;
    final bots = _bridgeBots(client);
    final cfg = WhatsAppBridgeConfig.of(client);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final e in bots.entries) ...[
            ListTile(
              leading: const Icon(Icons.link_off_outlined),
              title: Text(
                e.key == cfg.ownBot
                    ? 'Own bridge (home)'
                    : e.key == WhatsAppBridgeConfig.serverBot(client)
                    ? 'tjena server bridge'
                    : 'Bridge',
              ),
              subtitle: Text('${e.key}\n${e.value} chats, spaces and invites'),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _cleanupBridge(e.key),
            ),
            const Divider(height: 1),
          ],
          const ListTile(
            dense: true,
            title: Text(
              'For a bridge that broke off (phone reset, lost link): '
              'cleans up its chats so you can link WhatsApp again from scratch.',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMultiSelect() async {
    final client = Matrix.of(context).client;
    final allRooms = client.rooms.where((r) => !r.isSpace).toList();
    if (!mounted) return;
    final selected = await showDialog<List<Room>>(
      context: context,
      builder: (_) => _RoomPickerDialog(rooms: allRooms),
    );
    if (selected == null || selected.isEmpty) return;
    final confirmed = await _confirm(
      'Delete ${selected.length} selected room(s)?',
      'Matrix rooms will be left on the server.',
    );
    if (!confirmed) return;
    await _deleteRooms(selected);
  }

  Future<bool> _confirm(
    String title,
    String body, {
    String action = 'Delete',
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Tools'),
        leading: BackButton(onPressed: () => context.go('/rooms/settings')),
      ),
      body: _busy
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator.adaptive(),
                  for (final l in _bridgeLog ?? const <String>[])
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(l, textAlign: TextAlign.center),
                    ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionLabel(theme, 'CALLS'),
                const SizedBox(height: 8),
                _callsCard(theme),
                const SizedBox(height: 24),
                _sectionLabel(theme, 'BULK DELETE'),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.person_remove_outlined),
                        title: const Text('Delete all direct chats'),
                        subtitle: const Text(
                          'Removes all DMs (Matrix + WhatsApp) from this device',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _deleteAllDMs,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.group_remove_outlined),
                        title: const Text('Delete all group chats'),
                        subtitle: const Text(
                          'Removes all groups (Matrix + WhatsApp) from this device',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _deleteAllGroups,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: const Text('Decline all invites'),
                        subtitle: const Text(
                          'Chats, groups and spaces you were invited to',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _declineInvites,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: Icon(
                          Icons.delete_forever_outlined,
                          color: theme.colorScheme.error,
                        ),
                        title: const Text('Delete everything'),
                        subtitle: const Text(
                          'All chats, groups, spaces and invites',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _deleteEverything,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _sectionLabel(theme, 'WHATSAPP BRIDGE CLEANUP'),
                const SizedBox(height: 8),
                if (_bridgeLog != null && _bridgeLog!.isNotEmpty) ...[
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_bridgeLog!.join('\n')),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                _bridgeCard(),
                const SizedBox(height: 24),
                _sectionLabel(theme, 'SELECT & DELETE'),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.checklist_outlined),
                    title: const Text('Select rooms to delete'),
                    subtitle: const Text(
                      'Pick individual rooms to remove from this device',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openMultiSelect,
                  ),
                ),
                const SizedBox(height: 24),
                _sectionLabel(theme, 'ENCRYPTION / KEY BACKUP'),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.vpn_key_outlined),
                        title: const Text('Recovery key & chat backup'),
                        subtitle: const Text(
                          'Set up, unlock, or restore your encryption key '
                          'backup; view/enter the recovery key',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/backup'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.key_off_outlined),
                        title: const Text('Reset recovery key'),
                        subtitle: const Text(
                          'Generate a new recovery key (shows it once). Old key '
                          'and backup are replaced.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/backup?wipe=true'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _sectionLabel(theme, 'NOTE'),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Matrix rooms: you leave the room on the server; the room stays '
                    'in your account and can be rejoined.\n\n'
                    'WhatsApp rooms: removed from this device only; a chat comes back '
                    'when a new message arrives. Leaving a WhatsApp space hides it '
                    'until the account is removed.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      letterSpacing: 1.2,
    ),
  );
}

class _RoomPickerDialog extends StatefulWidget {
  final List<Room> rooms;
  const _RoomPickerDialog({required this.rooms});

  @override
  State<_RoomPickerDialog> createState() => _RoomPickerDialogState();
}

class _RoomPickerDialogState extends State<_RoomPickerDialog> {
  final _selected = <String>{};

  String _label(Room room) {
    final n = room.getLocalizedDisplayname();
    final type = room.isDirectChat ? ' (DM)' : ' (group)';
    return '$n$type';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select rooms to delete'),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.rooms.isEmpty
            ? const Text('No rooms found.')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.rooms.length,
                itemBuilder: (_, i) {
                  final room = widget.rooms[i];
                  return CheckboxListTile(
                    value: _selected.contains(room.id),
                    title: Text(
                      _label(room),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.add(room.id);
                      } else {
                        _selected.remove(room.id);
                      }
                    }),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  widget.rooms.where((r) => _selected.contains(r.id)).toList(),
                ),
          child: Text(
            _selected.isEmpty ? 'Delete' : 'Delete (${_selected.length})',
          ),
        ),
      ],
    );
  }
}
