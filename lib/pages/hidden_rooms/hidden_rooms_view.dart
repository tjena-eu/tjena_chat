// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/utils/hidden_rooms.dart';
import 'package:fluffychat/widgets/matrix.dart';

/// Lists the user's hidden chats, where they can be opened or unhidden.
class HiddenRoomsView extends StatelessWidget {
  const HiddenRoomsView({super.key});

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    return Scaffold(
      appBar: AppBar(
        leading: const Center(child: BackButton()),
        title: const Text('Hidden chats'),
      ),
      body: ValueListenableBuilder<Set<String>>(
        valueListenable: HiddenRooms.instance.notifier,
        builder: (context, ids, _) {
          final rooms = ids
              .map(client.getRoomById)
              .whereType<Room>()
              .toList()
            ..sort((a, b) => b.latestEventReceivedTime.compareTo(
                  a.latestEventReceivedTime,
                ));
          if (rooms.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No hidden chats.\n\nHide a chat from its menu (⋮ → Hide chat); '
                  'it then stays out of your list even when new messages arrive.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: rooms.length,
            itemBuilder: (context, i) {
              final room = rooms[i];
              return Row(
                children: [
                  Expanded(
                    child: ChatListItem(
                      room,
                      onTap: () => context.go('/rooms/${room.id}'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Unhide',
                    icon: const Icon(Icons.visibility_outlined),
                    onPressed: () => HiddenRooms.instance.unhide(room.id),
                  ),
                  const SizedBox(width: 8),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
