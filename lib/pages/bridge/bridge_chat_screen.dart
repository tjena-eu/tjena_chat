// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tjena_bridge/bridge_room_store.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

/// Full-screen chat view for a WhatsApp portal room.
class BridgeChatScreen extends StatefulWidget {
  final String roomID;

  const BridgeChatScreen({required this.roomID, super.key});

  @override
  State<BridgeChatScreen> createState() => _BridgeChatScreenState();
}

class _BridgeChatScreenState extends State<BridgeChatScreen> {
  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  bool _sending = false;
  StreamSubscription<BridgeEvent>? _sub;

  @override
  void initState() {
    super.initState();
    // Mark room as read when opened.
    final tl = BridgeRoomStore.instance.timelineFor(widget.roomID);
    if (tl.isNotEmpty) {
      TjenaBridge.instance.markRead(widget.roomID, tl.last.id).ignore();
    }
    // Listen for new events to auto-scroll and mark read.
    _sub = TjenaBridge.instance.events.listen((evt) {
      if (!mounted) return;
      if (evt.type == BridgeEventType.message &&
          evt.data['room_id'] == widget.roomID) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
          TjenaBridge.instance
              .markRead(widget.roomID,
                  (evt.data['event'] as Map)['id'] as String)
              .ignore();
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    _inputController.dispose();
    // Stop typing when leaving.
    TjenaBridge.instance.setTyping(widget.roomID, typing: false).ignore();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    _inputController.clear();
    setState(() => _sending = true);
    try {
      final msgID = 'tjena_${DateTime.now().millisecondsSinceEpoch}';
      await TjenaBridge.instance.sendText(widget.roomID, msgID, text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BridgeRoomStore.instance,
      builder: (context, _) {
        final room = BridgeRoomStore.instance.rooms
            .where((r) => r.id == widget.roomID)
            .firstOrNull;
        final timeline =
            BridgeRoomStore.instance.timelineFor(widget.roomID);
        final typing = BridgeRoomStore.instance.typingIn(widget.roomID);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(room?.name ?? widget.roomID),
                if (typing.isNotEmpty)
                  const Text('typing…',
                      style: TextStyle(
                          fontSize: 12, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  itemCount: timeline.length,
                  itemBuilder: (context, i) =>
                      _EventBubble(event: timeline[i]),
                ),
              ),
              _InputBar(
                controller: _inputController,
                sending: _sending,
                onSend: _send,
                onTyping: (v) => TjenaBridge.instance
                    .setTyping(widget.roomID, typing: v)
                    .ignore(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EventBubble extends StatelessWidget {
  final BridgeRoomEvent event;

  const _EventBubble({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (event.eventKind == 'reaction') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Center(
          child: Text(
            '${event.senderID} reacted ${event.reactionEmoji ?? ''}',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary),
          ),
        ),
      );
    }

    final isOwn = event.isOwn;
    final timeStr = DateFormat.Hm()
        .format(DateTime.fromMillisecondsSinceEpoch(event.ts * 1000));

    return Align(
      alignment: isOwn ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isOwn
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isOwn ? 16 : 4),
            bottomRight: Radius.circular(isOwn ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isOwn && event.senderName.isNotEmpty)
              Text(
                event.senderName,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary),
              ),
            Text(event.body),
            const SizedBox(height: 2),
            Text(
              timeStr,
              style: TextStyle(
                  fontSize: 10, color: theme.colorScheme.secondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final ValueChanged<bool> onTyping;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onTyping,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _wasTyping = false;
  Timer? _typingTimer;

  void _onChanged(String v) {
    final isTyping = v.trim().isNotEmpty;
    if (isTyping != _wasTyping) {
      _wasTyping = isTyping;
      widget.onTyping(isTyping);
    }
    if (isTyping) {
      _typingTimer?.cancel();
      // Auto-stop typing after 5s of inactivity.
      _typingTimer = Timer(const Duration(seconds: 5), () {
        if (_wasTyping) {
          _wasTyping = false;
          widget.onTyping(false);
        }
      });
    }
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: _onChanged,
                maxLines: null,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => widget.onSend(),
                decoration: const InputDecoration(
                  hintText: 'Message',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(24)),
                  ),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: widget.sending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              onPressed: widget.sending ? null : widget.onSend,
            ),
          ],
        ),
      ),
    );
  }
}
