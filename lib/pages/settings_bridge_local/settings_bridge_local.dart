// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import '../bridge/bridge_link_screen.dart';
import 'wa_chat_picker_screen.dart';

class SettingsBridgeLocal extends StatefulWidget {
  /// Which WhatsApp account this page manages ("default" = primary).
  final String accountId;
  const SettingsBridgeLocal({this.accountId = 'default', super.key});

  @override
  State<SettingsBridgeLocal> createState() => _SettingsBridgeLocalState();
}

class _SettingsBridgeLocalState extends State<SettingsBridgeLocal> {
  BridgeState _state = BridgeState.empty;
  StreamSubscription<BridgeEvent>? _sub;

  int _defaultDays = 30;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _refreshState();
    _loadPrefs();
    _sub = TjenaBridge.instance.events.listen((evt) {
      if (evt.type == BridgeEventType.state ||
          evt.type == BridgeEventType.linked ||
          evt.type == BridgeEventType.disconnected) {
        _refreshState();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final days = await WaMatrixBridge.instance.getDefaultBackfillDays();
    if (!mounted) return;
    setState(() => _defaultDays = days);
  }

  bool _askedLinkMode = false;

  Future<void> _refreshState() async {
    try {
      final s = await TjenaBridge.instance.getState(accountID: widget.accountId);
      if (mounted) setState(() => _state = s);
      // First time we observe a linked account and the user hasn't chosen how to
      // handle history yet, ask.
      if (s.linked && !_askedLinkMode) {
        _askedLinkMode = true;
        final mode = await WaMatrixBridge.instance.getLinkMode();
        if (mode.isEmpty && mounted) {
          await _showPostLinkDialog();
        }
      }
    } catch (_) {}
  }

  Future<void> _showPostLinkDialog() async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('WhatsApp linked'),
        content: const Text(
          'Your WhatsApp history is being loaded into the app in the '
          'background.\n\nHow should chats appear?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('silent'),
            child: const Text('Only on new message'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('all'),
            child: const Text('Create all chats'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final days = await _promptDays(
      choice == 'all'
          ? 'How many days of history per chat?'
          : 'Default days of history to load when a chat first receives a message?',
    );
    if (days == null) return;
    await WaMatrixBridge.instance.setLinkMode(choice);
    await WaMatrixBridge.instance.setDefaultBackfillDays(days);
    if (choice == 'all') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Creating all chats from cached history…'),
        ),
      );
      // Give the link-time history sync a moment to populate the cache, then
      // create every cached chat. (Re-running later is safe — it skips existing.)
      Future.delayed(const Duration(seconds: 5), () async {
        final n = await WaMatrixBridge.instance.syncAllCachedChats(days, accountId: widget.accountId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Synced $n cached chats')),
          );
        }
      });
    }
  }

  Future<int?> _promptDays(String message) async {
    final controller = TextEditingController(text: '30');
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backfill history'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
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
                .pop(int.tryParse(controller.text.trim()) ?? 30),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openLink() async {
    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => BridgeLinkScreen(accountId: widget.accountId)),
    );
    if (linked == true) _refreshState();
  }

  Future<void> _manualSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      // Refresh name and avatar for every known WA room.
      final client = Matrix.of(context).client;
      final waRooms = client.rooms.where(
        (r) => WaMatrixBridge.instance.isWaRoom(r.id),
      );
      for (final room in waRooms) {
        await WaMatrixBridge.instance.refreshRoom(room.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Refreshing names and avatars…')),
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
        title: const Text('Alle WA-Räume löschen?'),
        content: const Text(
          'Entfernt alle lokalen WhatsApp-Chatrooms aus der App. '
          'Nichts wird in WhatsApp selbst geändert. '
          'Neue Nachrichten erstellen die Räume erneut.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final client = Matrix.of(context).client;
    await WaMatrixBridge.instance.clearAllRooms(client);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Alle WA-Räume entfernt')),
    );
  }

  Future<void> _unlink() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink WhatsApp?'),
        content: const Text(
          'This disconnects WhatsApp on this device. Your WhatsApp account and '
          'other linked devices are not affected. You can re-link any time.',
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
      await TjenaBridge.instance.logout(accountID: widget.accountId);
    } catch (_) {}
    _refreshState();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Direct'),
        leading: BackButton(
          onPressed: () => context.go('/rooms/settings/local-bridges'),
        ),
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
                  label: const Text('Link WhatsApp'),
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
                  label: const Text('Sync chats'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _state.connected
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => WaChatPickerScreen(accountId: widget.accountId),
                            ),
                          )
                      : null,
                  icon: const Icon(Icons.checklist_outlined, size: 18),
                  label: const Text('Choose chats'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _clearAllRooms,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Alle WA-Räume löschen'),
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
          const SizedBox(height: 24),
          _sectionLabel(context, 'SYNC & HISTORY'),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              title: const Text('Default backfill (days)'),
              subtitle: const Text(
                'History loaded when a chat is selected or first receives a '
                'message. 0 = none.',
              ),
              trailing: SizedBox(
                width: 80,
                child: _DaysField(
                  value: _defaultDays,
                  onChanged: (v) {
                    setState(() => _defaultDays = v);
                    WaMatrixBridge.instance.setDefaultBackfillDays(v);
                  },
                ),
              ),
            ),
          ),
          if (_state.linked) ...[
            const SizedBox(height: 24),
            _sectionLabel(context, 'ACTIVE CHATS'),
            const SizedBox(height: 8),
            _WaRoomList(theme: theme),
          ],
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

class _DaysField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _DaysField({required this.value, required this.onChanged});

  @override
  State<_DaysField> createState() => _DaysFieldState();
}

class _DaysFieldState extends State<_DaysField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.value == 0 ? '' : widget.value.toString(),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      decoration: const InputDecoration(
        isDense: true,
        hintText: '∞',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      onChanged: (s) {
        final v = int.tryParse(s) ?? 0;
        widget.onChanged(v < 0 ? 0 : v);
      },
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  final BridgeState state;
  const _ConnectionCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconBg = state.linked
        ? const Color(0xFF25D366)
        : theme.colorScheme.surfaceContainerHighest;
    final iconFg =
        state.linked ? Colors.white : theme.colorScheme.onSurfaceVariant;

    String subtitle;
    if (!state.linked) {
      subtitle = 'Not linked';
    } else if (state.phone.isNotEmpty) {
      subtitle = state.phone;
      if (state.pushName.isNotEmpty) subtitle = '${state.pushName} · ${state.phone}';
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
              child: Icon(Icons.chat_rounded, color: iconFg, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'WhatsApp Direct',
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

class _WaRoomList extends StatelessWidget {
  final ThemeData theme;
  const _WaRoomList({required this.theme});

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final waRooms = client.rooms
        .where((r) => WaMatrixBridge.instance.isWaRoom(r.id))
        .toList();
    if (waRooms.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'No chats yet — they appear here as messages arrive.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      );
    }
    const maxShown = 8;
    final shown = waRooms.take(maxShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: shown
                .map(
                  (r) => ChatListItem(
                    r,
                    key: Key('wa_settings_${r.id}'),
                    onTap: () => context.go('/rooms/${r.id}'),
                  ),
                )
                .toList(),
          ),
        ),
        if (waRooms.length > maxShown)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '+ ${waRooms.length - maxShown} more — see them in the chat list',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final BridgeState state;
  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!state.linked) {
      return _badge(
        context,
        'Not linked — tap Link WhatsApp',
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
