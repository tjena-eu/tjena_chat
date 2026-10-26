// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
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
      if (room.membership == Membership.join) await room.leave();
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
          ? const Center(child: CircularProgressIndicator.adaptive())
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
                    ],
                  ),
                ),
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
