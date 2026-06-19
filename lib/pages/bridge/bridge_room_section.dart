// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:tjena_bridge/bridge_room_store.dart';
import 'package:tjena_bridge/tjena_bridge.dart';
import 'bridge_chat_list_item.dart';
import 'bridge_chat_screen.dart';
import 'bridge_link_screen.dart';

/// Thin section rendered above the Matrix room list in [ChatListViewBody].
/// Shows "WhatsApp (not linked)" or a list of WA portal rooms.
/// Uses [ListenableBuilder] so it rebuilds only when [BridgeRoomStore] changes.
class BridgeRoomSection extends StatefulWidget {
  const BridgeRoomSection({super.key});

  @override
  State<BridgeRoomSection> createState() => _BridgeRoomSectionState();
}

class _BridgeRoomSectionState extends State<BridgeRoomSection> {
  BridgeState _state = BridgeState.empty;
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    _refreshState();
    TjenaBridge.instance.events.listen((evt) {
      if (evt.type == BridgeEventType.state ||
          evt.type == BridgeEventType.linked ||
          evt.type == BridgeEventType.disconnected) {
        _refreshState();
      }
    });
  }

  Future<void> _refreshState() async {
    try {
      final s = await TjenaBridge.instance.getState();
      if (mounted) setState(() => _state = s);
    } catch (_) {}
  }

  Future<void> _openLink() async {
    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const BridgeLinkScreen()),
    );
    if (linked == true) _refreshState();
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await TjenaBridge.instance.logout();
    } catch (_) {}
    _refreshState();
  }

  void _openRoom(String roomID) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BridgeChatScreen(roomID: roomID),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: BridgeRoomStore.instance,
      builder: (context, _) {
        final rooms = BridgeRoomStore.instance.rooms;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Section header
            InkWell(
              onTap: _state.linked
                  ? () => setState(() => _expanded = !_expanded)
                  : _openLink,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.chat_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _state.linked
                            ? 'WA_local${_state.phone.isNotEmpty ? ' (${_state.phone})' : ''}'
                            : 'WhatsApp (tap to link)',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    if (_state.linked && !_state.connected)
                      const Icon(Icons.wifi_off, size: 14),
                    if (_state.linked)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 18),
                        tooltip: 'Manage WhatsApp connection',
                        onSelected: (v) {
                          if (v == 'manage') _openLink();
                          if (v == 'unlink') _unlink();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'manage',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.link),
                              title: Text('Manage / re-link'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'unlink',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.link_off, color: Colors.redAccent),
                              title: Text('Unlink WhatsApp'),
                            ),
                          ),
                        ],
                      ),
                    if (_state.linked)
                      Icon(
                        _expanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                      ),
                  ],
                ),
              ),
            ),

            // Room list (collapsed or no rooms)
            if (_state.linked && _expanded && rooms.isNotEmpty)
              ...rooms.map(
                (room) => BridgeChatListItem(
                  room: room,
                  onTap: () => _openRoom(room.id),
                ),
              ),

            if (_state.linked && _expanded && rooms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'No WhatsApp chats yet — they appear as messages arrive.',
                  style: TextStyle(fontSize: 13),
                ),
              ),

            const Divider(height: 1),
          ],
        );
      },
    );
  }
}
