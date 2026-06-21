// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:fluffychat/utils/wa_matrix_bridge.dart';

/// Lists every WhatsApp chat (saved contacts + joined groups) and lets the user
/// pick which ones to sync into the bridge as rooms. Newly-checked chats get a
/// room created and (optionally) N days of history backfilled; unchecked chats
/// have their room removed.
class WaChatPickerScreen extends StatefulWidget {
  const WaChatPickerScreen({super.key});

  @override
  State<WaChatPickerScreen> createState() => _WaChatPickerScreenState();
}

class _WaChatPickerScreenState extends State<WaChatPickerScreen> {
  List<Map<String, dynamic>> _chats = [];
  final _selected = <String>{}; // jids currently checked
  final _initiallySynced = <String>{}; // jids synced when the screen opened
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final chats = await WaMatrixBridge.instance.listChatsWithStatus();
      _selected.clear();
      _initiallySynced.clear();
      for (final c in chats) {
        if (c['synced'] as bool? ?? false) {
          _selected.add(c['jid'] as String);
          _initiallySynced.add(c['jid'] as String);
        }
      }
      if (!mounted) return;
      setState(() {
        _chats = chats;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<int?> _askDays() async {
    final controller = TextEditingController(text: '30');
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backfill history'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'How many days of message history should be loaded for the '
              'newly added chats?',
            ),
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
                  Navigator.of(context).pop(int.tryParse(v.trim()) ?? 0),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(0),
            child: const Text('No history'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(int.tryParse(controller.text.trim()) ?? 0),
            child: const Text('Load'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final toAdd =
        _selected.where((j) => !_initiallySynced.contains(j)).toList();
    final toRemove =
        _initiallySynced.where((j) => !_selected.contains(j)).toList();

    if (toAdd.isEmpty && toRemove.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    var days = 0;
    if (toAdd.isNotEmpty) {
      final d = await _askDays();
      if (d == null) return; // dialog dismissed → abort save
      days = d;
    }

    setState(() => _saving = true);
    try {
      for (final jid in toAdd) {
        final chat = _chats.firstWhere((c) => c['jid'] == jid);
        await WaMatrixBridge.instance.syncChat(
          jid,
          chat['name'] as String? ?? '',
          chat['is_group'] as bool? ?? false,
          days,
        );
      }
      for (final jid in toRemove) {
        await WaMatrixBridge.instance.unsyncChat(jid);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added ${toAdd.length}, removed ${toRemove.length} chat(s)'
            '${days > 0 ? ' · loading $days days of history' : ''}',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filter.isEmpty
        ? _chats
        : _chats.where((c) {
            final name = (c['name'] as String? ?? '').toLowerCase();
            final phone = (c['phone'] as String? ?? '').toLowerCase();
            final jid = (c['jid'] as String? ?? '').toLowerCase();
            final f = _filter.toLowerCase();
            return name.contains(f) || phone.contains(f) || jid.contains(f);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose WhatsApp chats'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text('Apply (${_selected.length})'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            color: theme.colorScheme.error, size: 48),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(
                            onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search chats',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _filter = v),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final c = filtered[i];
                          final jid = c['jid'] as String;
                          final isGroup = c['is_group'] as bool? ?? false;
                          final name = c['name'] as String? ?? '';
                          final phone = c['phone'] as String? ?? '';
                          final subtitle =
                              phone.isNotEmpty ? phone : jid.split('@').first;
                          final title =
                              name.isNotEmpty ? name : subtitle;
                          return CheckboxListTile(
                            value: _selected.contains(jid),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(jid);
                              } else {
                                _selected.remove(jid);
                              }
                            }),
                            secondary: CircleAvatar(
                              child: Icon(
                                isGroup ? Icons.group : Icons.person,
                              ),
                            ),
                            title: Text(title),
                            subtitle: name.isNotEmpty ? Text(subtitle) : null,
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
