// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

/// Hub for the on-device (local) bridges. Lists each bridge (WhatsApp, Signal)
/// with its current account/connection state; tapping opens that bridge's
/// settings (link/disconnect, resync, choose chats, …).
class LocalBridgesHub extends StatefulWidget {
  const LocalBridgesHub({super.key});

  @override
  State<LocalBridgesHub> createState() => _LocalBridgesHubState();
}

class _LocalBridgesHubState extends State<LocalBridgesHub> {
  StreamSubscription<BridgeEvent>? _sub;
  BridgeState _wa = BridgeState.empty;
  SignalBridgeState _sig = SignalBridgeState.empty;

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
      final wa = await TjenaBridge.instance.getState();
      final sig = await TjenaBridge.instance.getSignalState();
      if (mounted) {
        setState(() {
          _wa = wa;
          _sig = sig;
        });
      }
    } catch (_) {}
  }

  String _waSubtitle() {
    if (!_wa.linked) return 'Not linked';
    final who = _wa.phone.isNotEmpty ? _wa.phone : 'linked';
    return _wa.connected ? 'Connected · $who' : 'Linked · $who (offline)';
  }

  String _sigSubtitle() {
    if (!_sig.linked) return 'Not linked';
    final who = _sig.phone.isNotEmpty ? _sig.phone : 'linked';
    return _sig.connected ? 'Connected · $who' : 'Linked · $who (offline)';
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
              'cloud involved. Each account is managed independently.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: const Color(0xFF25D366),
                child: const Icon(Icons.chat_rounded, color: Colors.white),
              ),
              title: const Text('WhatsApp'),
              subtitle: Text(_waSubtitle()),
              trailing: Icon(Icons.circle,
                  size: 12, color: dot(_wa.connected, _wa.linked)),
              onTap: () => context.go('/rooms/settings/bridge-local'),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF3A76F0),
                child: Icon(Icons.signal_cellular_alt, color: Colors.white),
              ),
              title: const Text('Signal'),
              subtitle: Text(_sigSubtitle()),
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
