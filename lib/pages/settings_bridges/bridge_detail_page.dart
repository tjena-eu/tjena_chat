// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../widgets/matrix.dart';
import '../../widgets/mxc_image.dart';
import 'bridge_definition.dart';
import 'settings_bridges.dart';

class BridgeDetailPage extends StatefulWidget {
  final BridgeEntry entry;
  const BridgeDetailPage({required this.entry, super.key});

  @override
  State<BridgeDetailPage> createState() => _BridgeDetailPageState();
}

class _BridgeDetailPageState extends State<BridgeDetailPage> {
  Timeline? _timeline;
  List<Event> _botMessages = [];
  StreamSubscription? _syncSub;
  bool _loadingTimeline = true;
  bool _sendingCommand = false;
  String? _activeCommand;

  BridgeEntry get entry => widget.entry;
  Client get client => Matrix.of(context).client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _ensureDmRoom();
      await _loadTimeline();
      _syncSub = client.onSync.stream.listen((_) => _refreshMessages());
    });
  }

  Future<void> _ensureDmRoom() async {
    if (entry.dmRoom != null) return;
    try {
      final roomId = await client.startDirectChat(entry.botUserId);
      entry.dmRoom = client.getRoomById(roomId);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[BridgeDetail] Failed to open DM with bot: $e');
    }
  }

  Future<void> _loadTimeline() async {
    final room = entry.dmRoom;
    if (room == null) {
      if (mounted) setState(() => _loadingTimeline = false);
      return;
    }
    try {
      _timeline = await room.getTimeline();
      _refreshMessages();
    } catch (e) {
      debugPrint('[BridgeDetail] Failed to load timeline: $e');
    }
    if (mounted) setState(() => _loadingTimeline = false);
  }

  void _refreshMessages() {
    final timeline = _timeline;
    if (timeline == null || !mounted) return;
    setState(() {
      _botMessages = timeline.events
          .where(
            (e) =>
                e.senderId == entry.botUserId &&
                (e.type == EventTypes.Message ||
                    e.type == EventTypes.Sticker) &&
                !e.redacted,
          )
          .take(6)
          .toList();
    });
  }

  Future<void> _onActionTap(BridgeAction action) async {
    if (action.requiresLoginWarning) {
      final confirmed = await _showLoginWarning(action);
      if (!confirmed) return;
    }
    if (action.requiresPhoneNumber) {
      final phone = await _showPhoneDialog();
      if (phone == null || phone.isEmpty) return;
      await _sendCommand('${action.command} $phone');
    } else {
      await _sendCommand(action.command);
    }
  }

  Future<String?> _showPhoneDialog() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Enter phone number'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '+1234567890',
            labelText: 'Phone number with country code',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<bool> _showLoginWarning(BridgeAction action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => _LoginWarningDialog(
        bridgeName: entry.def.name,
        docsUrl: entry.def.docsUrl,
      ),
    );
    return result == true;
  }

  Future<void> _sendCommand(String command) async {
    final room = entry.dmRoom;
    if (room == null) return;
    setState(() {
      _sendingCommand = true;
      _activeCommand = command;
    });
    try {
      await room.sendTextEvent(command);
    } finally {
      if (mounted) {
        setState(() {
          _sendingCommand = false;
          _activeCommand = null;
        });
      }
    }
  }

  void _openFullChat() {
    final room = entry.dmRoom;
    if (room == null) return;
    context.go('/rooms/${room.id}');
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _timeline?.cancelSubscriptions();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(entry.def.name),
        leading: BackButton(
          onPressed: () => context.go('/rooms/settings/bridges'),
        ),
        actions: [
          if (entry.dmRoom != null)
            IconButton(
              icon: const Icon(Icons.open_in_new_outlined),
              tooltip: 'Open full chat with bot',
              onPressed: _openFullChat,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _BridgeHeaderCard(entry: entry),
          const SizedBox(height: 20),
          Text(
            'ACTIONS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entry.def.actions
                .map(
                  (action) => _ActionChip(
                    action: action,
                    isLoading:
                        _sendingCommand && _activeCommand == action.command,
                    isDisabled: _sendingCommand,
                    onPressed: () => _onActionTap(action),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                'BRIDGE RESPONSES',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (_loadingTimeline)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_loadingTimeline && _botMessages.isEmpty)
            _EmptyMessagesCard(hasDmRoom: entry.dmRoom != null)
          else
            ..._botMessages.map(
              (e) => _BotMessageBubble(
                event: e,
                color: entry.def.color,
              ),
            ),
          if (entry.dmRoom != null) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _openFullChat,
              icon: const Icon(Icons.chat_outlined),
              label: Text('Full chat with ${entry.def.name} bot'),
            ),
          ],
        ],
      ),
    );
  }
}

class _BridgeHeaderCard extends StatelessWidget {
  final BridgeEntry entry;
  const _BridgeHeaderCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: entry.def.color,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.chat_outlined, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.def.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.botUserId,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Bot available on server',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final BridgeAction action;
  final bool isLoading;
  final bool isDisabled;
  final VoidCallback onPressed;

  const _ActionChip({
    required this.action,
    required this.isLoading,
    required this.isDisabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilledButton.tonalIcon(
      style: action.isDestructive
          ? FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.onErrorContainer,
            )
          : null,
      onPressed: isDisabled ? null : onPressed,
      icon: isLoading
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator.adaptive(
                strokeWidth: 2,
                backgroundColor: action.isDestructive
                    ? theme.colorScheme.onErrorContainer.withAlpha(60)
                    : null,
              ),
            )
          : Icon(action.icon, size: 18),
      label: Text(action.label),
    );
  }
}

class _EmptyMessagesCard extends StatelessWidget {
  final bool hasDmRoom;
  const _EmptyMessagesCard({required this.hasDmRoom});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        hasDmRoom
            ? 'No responses yet. Tap an action above to interact with the bridge.'
            : 'Opening a chat with the bridge bot…',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _BotMessageBubble extends StatelessWidget {
  final Event event;
  final Color color;
  const _BotMessageBubble({required this.event, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage = event.messageType == MessageTypes.Image ||
        event.messageType == MessageTypes.Sticker;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: color, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: MxcImage(
                event: event,
                width: double.infinity,
                height: 220,
                fit: BoxFit.contain,
                isThumbnail: false,
              ),
            )
          else
            Text(
              event.body,
              style: theme.textTheme.bodyMedium,
            ),
          const SizedBox(height: 6),
          Text(
            _timeLabel(event.originServerTs),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _timeLabel(DateTime ts) {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _LoginWarningDialog extends StatelessWidget {
  final String bridgeName;
  final String docsUrl;

  const _LoginWarningDialog({
    required this.bridgeName,
    required this.docsUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog.adaptive(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: theme.colorScheme.error,
        size: 40,
      ),
      title: Text('Before connecting $bridgeName'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _WarningItem(
            icon: Icons.devices_outlined,
            text:
                'This is a linked (secondary) device. You need your primary $bridgeName account '
                'active and logged in on another device to complete setup.',
          ),
          const SizedBox(height: 12),
          _WarningItem(
            icon: Icons.gpp_maybe_outlined,
            text:
                '$bridgeName bridges use the unofficial web/mobile API. '
                'Using a bridge may violate the terms of service and could '
                'result in your account being banned or restricted.',
          ),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => launchUrlString(docsUrl),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.open_in_new_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Bridge documentation',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('I understand, continue'),
        ),
      ],
    );
  }
}

class _WarningItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _WarningItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}
