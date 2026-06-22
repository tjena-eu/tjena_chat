// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tjena_bridge/bridge_room_store.dart';

class BridgeChatListItem extends StatelessWidget {
  final BridgeRoom room;
  final bool selected;
  final VoidCallback onTap;

  const BridgeChatListItem({
    required this.room,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ts = room.lastEventTs;
    final timeStr = ts != null
        ? DateFormat.Hm().format(
            DateTime.fromMillisecondsSinceEpoch(ts * 1000))
        : '';

    return Material(
      color: selected
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          child: Text(
            room.name.isNotEmpty ? room.name[0].toUpperCase() : 'W',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: room.hasUnread
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
            if (timeStr.isNotEmpty)
              Text(
                timeStr,
                style: TextStyle(
                  fontSize: 12,
                  color: room.hasUnread
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondary,
                ),
              ),
          ],
        ),
        subtitle: Row(
          children: [
            Expanded(
              child: Text(
                room.lastEventBody ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.colorScheme.secondary,
                  fontWeight: room.hasUnread
                      ? FontWeight.w500
                      : FontWeight.normal,
                ),
              ),
            ),
            if (room.hasUnread)
              Container(
                margin: const EdgeInsets.only(left: 4),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
