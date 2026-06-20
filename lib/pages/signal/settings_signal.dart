// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/signal_matrix_bridge.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import 'signal_link_screen.dart';

class SettingsSignal extends StatefulWidget {
  const SettingsSignal({super.key});

  @override
  State<SettingsSignal> createState() => _SettingsSignalState();
}

class _SettingsSignalState extends State<SettingsSignal> {
  SignalBridgeState _state = SignalBridgeState.empty;
  StreamSubscription<BridgeEvent>? _sub;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _refreshState();
    _sub = TjenaBridge.instance.events.listen((evt) {
      if (evt.type == BridgeEventType.signalState ||
          evt.type == BridgeEventType.signalLinked) {
        _refreshState();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refreshState() async {
    try {
      final s = await TjenaBridge.instance.getSignalState();
      if (mounted) setState(() => _state = s);
    } catch (_) {}
  }

  Future<void> _openLink() async {
    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const SignalLinkScreen()),
    );
    if (linked == true) _refreshState();
  }

  Future<void> _manualSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await TjenaBridge.instance.signalManualSync();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signal sync started')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _clearAllRooms() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all Signal rooms?'),
        content: const Text(
          'Removes all local Signal chat rooms from the app. '
          'Nothing changes in Signal itself. '
          'Rooms reappear when new messages arrive.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final client = Matrix.of(context).client;
    await SignalMatrixBridge.instance.clearAllRooms(client);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All Signal rooms removed')),
    );
  }

  Future<void> _unlink() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink Signal?'),
        content: const Text(
          'Disconnects Signal on this device. Your Signal account and '
          'other linked devices are not affected. Re-link any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await TjenaBridge.instance.signalLogout();
    } catch (_) {}
    _refreshState();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Signal Direct'),
        leading: BackButton(onPressed: () => context.go('/rooms/settings')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ConnectionCard(state: _state),
          const SizedBox(height: 20),
          _sectionLabel(context, 'ACTIONS'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!_state.linked)
                FilledButton.icon(
                  onPressed: _openLink,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Link Signal'),
                ),
              if (_state.linked) ...[
                FilledButton.tonalIcon(
                  onPressed: _openLink,
                  icon: const Icon(Icons.manage_accounts_outlined, size: 18),
                  label: const Text('Manage / Re-link'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _state.connected ? _manualSync : null,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 18),
                  label: const Text('Sync contacts'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _clearAllRooms,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Delete all Signal rooms'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _unlink,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  icon: const Icon(Icons.link_off, size: 18),
                  label: const Text('Unlink'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  final SignalBridgeState state;
  const _ConnectionCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconBg = state.linked
        ? const Color(0xFF3A76F0) // Signal blue
        : theme.colorScheme.surfaceContainerHighest;
    final iconFg =
        state.linked ? Colors.white : theme.colorScheme.onSurfaceVariant;

    String subtitle;
    if (!state.linked) {
      subtitle = 'Not linked';
    } else if (state.phone.isNotEmpty) {
      subtitle = state.phone;
    } else {
      subtitle = state.connected ? 'Connected' : 'Disconnected';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.signal_cellular_alt, color: iconFg, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Signal Direct',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  _StatusBadge(state: state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final SignalBridgeState state;
  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!state.linked) {
      return _badge(
        context,
        'Not linked — tap Link Signal',
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      );
    }
    if (state.connected) {
      return _badge(
        context,
        'Connected',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      );
    }
    return _badge(
      context,
      'Disconnected — will reconnect',
      theme.colorScheme.surfaceContainerHighest,
      theme.colorScheme.onSurfaceVariant,
    );
  }

  Widget _badge(BuildContext context, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
