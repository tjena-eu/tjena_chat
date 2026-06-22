// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import '../bridge/bridge_link_screen.dart';

/// Hub for the on-device (local) bridges. WhatsApp supports multiple accounts;
/// Signal is a single account. Each entry opens its own settings (link /
/// disconnect, resync, choose chats, …).
class LocalBridgesHub extends StatefulWidget {
  const LocalBridgesHub({super.key});

  @override
  State<LocalBridgesHub> createState() => _LocalBridgesHubState();
}

class _LocalBridgesHubState extends State<LocalBridgesHub> {
  StreamSubscription<BridgeEvent>? _sub;
  List<Map<String, dynamic>> _waAccounts = [];
  SignalBridgeState _sig = SignalBridgeState.empty;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = TjenaBridge.instance.events.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final accounts = await TjenaBridge.instance.listAccounts();
      final sig = await TjenaBridge.instance.getSignalState();
      if (mounted) {
        setState(() {
          _waAccounts = accounts;
          _sig = sig;
        });
      }
    } catch (_) {}
  }

  Future<void> _addAccount() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final id = await TjenaBridge.instance.addAccount();
      if (id.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not create account')),
          );
        }
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => BridgeLinkScreen(accountId: id)),
      );
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAccount(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove account?'),
        content: const Text(
          'Logs out and removes this WhatsApp account and its chats from the '
          'app. WhatsApp itself is unaffected.',
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
    );
    if (ok != true) return;
    try {
      await TjenaBridge.instance.removeAccount(id);
    } catch (_) {}
    await _refresh();
  }

  String _accSubtitle(Map<String, dynamic> a) {
    final linked = a['linked'] as bool? ?? false;
    final connected = a['connected'] as bool? ?? false;
    final phone = a['phone'] as String? ?? '';
    if (!linked) return 'Not linked — tap to set up';
    final who = phone.isNotEmpty ? phone : 'linked';
    return connected ? 'Connected · $who' : 'Linked · $who (offline)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color dot(bool connected, bool linked) => connected
        ? const Color(0xFF25D366)
        : (linked ? Colors.orange : theme.colorScheme.outline);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Bridges'),
        leading: BackButton(onPressed: () => context.go('/rooms/settings')),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'On-device bridges run entirely on your phone — no homeserver or '
              'cloud. You can link multiple WhatsApp accounts.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('WHATSAPP ACCOUNTS',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 1.2,
                )),
          ),
          for (final a in _waAccounts)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFF25D366),
                  child: const Icon(Icons.chat_rounded, color: Colors.white),
                ),
                title: Text(
                  (a['id'] as String? ?? '') == 'default'
                      ? 'WhatsApp'
                      : 'WhatsApp (${(a['phone'] as String?)?.isNotEmpty == true ? a['phone'] : 'account'})',
                ),
                subtitle: Text(_accSubtitle(a)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle,
                        size: 12,
                        color: dot(a['connected'] as bool? ?? false,
                            a['linked'] as bool? ?? false)),
                    if ((a['id'] as String? ?? '') != 'default')
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            _removeAccount(a['id'] as String? ?? ''),
                      ),
                  ],
                ),
                onTap: () => context.go(
                  '/rooms/settings/bridge-local?account=${a['id']}',
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _addAccount,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: const Text('Add WhatsApp account'),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('SIGNAL',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 1.2,
                )),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF3A76F0),
                child: Icon(Icons.signal_cellular_alt, color: Colors.white),
              ),
              title: const Text('Signal'),
              subtitle: Text(
                !_sig.linked
                    ? 'Not linked'
                    : (_sig.connected
                        ? 'Connected · ${_sig.phone}'
                        : 'Linked · ${_sig.phone} (offline)'),
              ),
              trailing: Icon(Icons.circle,
                  size: 12, color: dot(_sig.connected, _sig.linked)),
              onTap: () => context.go('/rooms/settings/signal'),
            ),
          ),
        ],
      ),
    );
  }
}
