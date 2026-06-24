// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:fluffychat/utils/wa_matrix_bridge.dart';

enum _SortKey { recent, name }

/// Lists every WhatsApp chat (saved contacts + joined groups) with avatars,
/// search and sorting.
///
/// Two modes:
/// - default (sync mode): multi-select which chats to sync into the bridge as
///   rooms. Newly-checked chats get a room + optional backfill; unchecked chats
///   have their room removed.
/// - [pickToOpen]: single-tap to open a chat (creating the room if needed) and
///   pop the chosen Matrix room id. Used by "New chat → WhatsApp → choose an
///   existing chat", so both entry points share this one advanced view.
class WaChatPickerScreen extends StatefulWidget {
  final String accountId;
  final bool pickToOpen;
  const WaChatPickerScreen({
    this.accountId = 'default',
    this.pickToOpen = false,
    super.key,
  });

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
  _SortKey _sortKey = _SortKey.recent;
  bool _sortDescending = true; // recent: newest first; name: Z→A
  String? _opening; // jid currently being opened (pickToOpen mode)

  // jid → resolved avatar URL ('' = none, missing = not yet fetched).
  final _avatarUrls = <String, String>{};

  Future<String> _avatarUrl(String jid) async {
    final cached = _avatarUrls[jid];
    if (cached != null) return cached;
    final url = await WaMatrixBridge.instance.chatAvatarUrl(jid, accountId: widget.accountId);
    _avatarUrls[jid] = url;
    return url;
  }

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
      final chats = await WaMatrixBridge.instance.listChatsWithStatus(accountId: widget.accountId);
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

  /// pickToOpen mode: open (creating if needed) the tapped chat and pop its
  /// Matrix room id to the caller.
  Future<void> _openChat(Map<String, dynamic> c) async {
    final jid = c['jid'] as String;
    setState(() => _opening = jid);
    try {
      final roomId = await WaMatrixBridge.instance.openChatRoom(
        jid,
        c['name'] as String? ?? '',
        c['is_group'] as bool? ?? false,
        accountId: widget.accountId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(roomId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _opening = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open chat: $e')),
      );
    }
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
          accountId: widget.accountId,
        );
      }
      for (final jid in toRemove) {
        await WaMatrixBridge.instance.unsyncChat(jid, accountId: widget.accountId);
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
    final filtered = (_filter.isEmpty
        ? List<Map<String, dynamic>>.from(_chats)
        : _chats.where((c) {
            final name = (c['name'] as String? ?? '').toLowerCase();
            final phone = (c['phone'] as String? ?? '').toLowerCase();
            final jid = (c['jid'] as String? ?? '').toLowerCase();
            final f = _filter.toLowerCase();
            return name.contains(f) || phone.contains(f) || jid.contains(f);
          }).toList());

    String displayName(Map<String, dynamic> c) {
      final n = (c['name'] as String? ?? '');
      if (n.isNotEmpty) return n;
      final p = (c['phone'] as String? ?? '');
      return p.isNotEmpty ? p : (c['jid'] as String? ?? '').split('@').first;
    }

    filtered.sort((a, b) {
      int cmp;
      if (_sortKey == _SortKey.recent) {
        final la = a['last_activity'] as int? ?? 0;
        final lb = b['last_activity'] as int? ?? 0;
        cmp = la.compareTo(lb);
        // tie-break equal/zero activity by name so it's stable
        if (cmp == 0) {
          cmp = displayName(a).toLowerCase().compareTo(
                displayName(b).toLowerCase(),
              );
          return cmp; // name tie-break is always ascending
        }
      } else {
        cmp = displayName(a).toLowerCase().compareTo(
              displayName(b).toLowerCase(),
            );
      }
      return _sortDescending ? -cmp : cmp;
    });

    final visibleJids = filtered.map((c) => c['jid'] as String).toSet();
    final allVisibleSelected =
        visibleJids.isNotEmpty && visibleJids.every(_selected.contains);

    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.pickToOpen ? 'Open WhatsApp chat' : 'Choose WhatsApp chats'),
        actions: [
          if (!widget.pickToOpen && !_loading && _error == null)
            IconButton(
              tooltip: allVisibleSelected ? 'Deselect all' : 'Select all',
              onPressed: () => setState(() {
                if (allVisibleSelected) {
                  _selected.removeAll(visibleJids);
                } else {
                  _selected.addAll(visibleJids);
                }
              }),
              icon: Icon(
                allVisibleSelected
                    ? Icons.deselect_outlined
                    : Icons.select_all_outlined,
              ),
            ),
          IconButton(
            tooltip: _sortDescending ? 'Descending' : 'Ascending',
            onPressed: () =>
                setState(() => _sortDescending = !_sortDescending),
            icon: Icon(
              _sortDescending
                  ? Icons.arrow_downward_outlined
                  : Icons.arrow_upward_outlined,
            ),
          ),
          PopupMenuButton<_SortKey>(
            tooltip: 'Sort by',
            icon: const Icon(Icons.sort),
            initialValue: _sortKey,
            onSelected: (m) => setState(() => _sortKey = m),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _SortKey.recent,
                child: Text('Sort by: Recent activity'),
              ),
              PopupMenuItem(
                value: _SortKey.name,
                child: Text('Sort by: Name'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: (_loading || widget.pickToOpen)
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
                          final avatar = _ChatAvatar(
                            jid: jid,
                            isGroup: isGroup,
                            urlFuture: _avatarUrl(jid),
                          );
                          if (widget.pickToOpen) {
                            return ListTile(
                              leading: avatar,
                              title: Text(title),
                              subtitle: name.isNotEmpty ? Text(subtitle) : null,
                              trailing: _opening == jid
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : ((c['synced'] as bool? ?? false)
                                      ? const Icon(Icons.check, size: 18)
                                      : null),
                              onTap:
                                  _opening == null ? () => _openChat(c) : null,
                            );
                          }
                          return CheckboxListTile(
                            value: _selected.contains(jid),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(jid);
                              } else {
                                _selected.remove(jid);
                              }
                            }),
                            secondary: avatar,
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

/// Lazily-loaded circular WhatsApp profile picture for a chat, with a
/// person/group icon fallback while loading or when no picture exists.
class _ChatAvatar extends StatelessWidget {
  final String jid;
  final bool isGroup;
  final Future<String> urlFuture;

  const _ChatAvatar({
    required this.jid,
    required this.isGroup,
    required this.urlFuture,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      child: Icon(isGroup ? Icons.group : Icons.person),
    );
    return FutureBuilder<String>(
      future: urlFuture,
      builder: (context, snapshot) {
        final url = snapshot.data ?? '';
        if (url.isEmpty) return fallback;
        return CircleAvatar(
          backgroundColor: Colors.transparent,
          backgroundImage: NetworkImage(url),
          onBackgroundImageError: (_, __) {},
          child: null,
        );
      },
    );
  }
}
