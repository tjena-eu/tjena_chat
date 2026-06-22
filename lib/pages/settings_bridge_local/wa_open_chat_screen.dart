// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:fluffychat/utils/wa_matrix_bridge.dart';

/// Lists WhatsApp chats; tapping one opens it (creating the room if needed) and
/// pops the chosen Matrix room id. Used by the "New chat → WhatsApp → choose an
/// existing chat" flow.
class WaOpenChatScreen extends StatefulWidget {
  final String accountId;
  const WaOpenChatScreen({this.accountId = 'default', super.key});

  @override
  State<WaOpenChatScreen> createState() => _WaOpenChatScreenState();
}

class _WaOpenChatScreenState extends State<WaOpenChatScreen> {
  List<Map<String, dynamic>> _chats = [];
  bool _loading = true;
  String? _error;
  String _filter = '';
  String? _opening;

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
      final chats =
          await WaMatrixBridge.instance.listChatsWithStatus(accountId: widget.accountId);
      chats.sort((a, b) {
        final la = a['last_activity'] as int? ?? 0;
        final lb = b['last_activity'] as int? ?? 0;
        return lb.compareTo(la);
      });
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

  Future<void> _open(Map<String, dynamic> c) async {
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

  String _title(Map<String, dynamic> c) {
    final n = c['name'] as String? ?? '';
    if (n.isNotEmpty) return n;
    final p = c['phone'] as String? ?? '';
    return p.isNotEmpty ? p : (c['jid'] as String? ?? '').split('@').first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filter.isEmpty
        ? _chats
        : _chats.where((c) {
            final f = _filter.toLowerCase();
            return _title(c).toLowerCase().contains(f) ||
                (c['phone'] as String? ?? '').contains(f);
          }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Open WhatsApp chat')),
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
                          final phone = c['phone'] as String? ?? '';
                          final subtitle =
                              phone.isNotEmpty ? phone : jid.split('@').first;
                          final name = c['name'] as String? ?? '';
                          return ListTile(
                            leading: CircleAvatar(
                              child: Icon(isGroup ? Icons.group : Icons.person),
                            ),
                            title: Text(_title(c)),
                            subtitle: name.isNotEmpty ? Text(subtitle) : null,
                            trailing: _opening == jid
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : (c['synced'] as bool? ?? false)
                                    ? const Icon(Icons.check, size: 18)
                                    : null,
                            onTap: _opening == null ? () => _open(c) : null,
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
