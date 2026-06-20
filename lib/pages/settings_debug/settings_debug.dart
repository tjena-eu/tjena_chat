// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

class SettingsDebug extends StatefulWidget {
  const SettingsDebug({super.key});

  @override
  State<SettingsDebug> createState() => _SettingsDebugState();
}

class _SettingsDebugState extends State<SettingsDebug> {
  bool _busy = false;

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
    if (WaMatrixBridge.instance.isWaRoom(room.id)) {
      await WaMatrixBridge.instance.removeRoom(client, room.id);
    } else {
      try {
        if (room.membership == Membership.join) await room.leave();
      } catch (_) {}
      try {
        await room.forget();
      } catch (_) {}
    }
  }

  Future<void> _deleteAllDMs() async {
    final client = Matrix.of(context).client;
    final dms = client.rooms.where((r) => !r.isSpace && r.isDirectChat).toList()
      ..addAll(
        client.rooms
            .where((r) => WaMatrixBridge.instance.isWaRoom(r.id))
            .where((r) {
          final state = r.getState('org.tjena.bridge.local');
          return state?.content['is_dm'] as bool? ?? false;
        }),
      );
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

  Future<bool> _confirm(String title, String body) async {
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
            child: const Text('Delete'),
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
                    'WhatsApp rooms: removed from this device only; they reappear '
                    'when new messages arrive.',
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
    final tag = WaMatrixBridge.instance.isWaRoom(room.id) ? ' [WA]' : '';
    final type = room.isDirectChat ? ' (DM)' : ' (group)';
    return '$n$tag$type';
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
                    widget.rooms
                        .where((r) => _selected.contains(r.id))
                        .toList(),
                  ),
          child: Text(
            _selected.isEmpty ? 'Delete' : 'Delete (${_selected.length})',
          ),
        ),
      ],
    );
  }
}
