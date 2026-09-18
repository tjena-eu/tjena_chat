// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';

/// A small coloured dot showing whether the WhatsApp link for a bridged room is
/// currently up: green = connected, orange = reconnecting, red = offline (a
/// message sent now would not go through).
///
/// Renders nothing for rooms that aren't WhatsApp-bridged, so it is safe to
/// place unconditionally in the chat app bar.
class WaConnectionIndicator extends StatefulWidget {
  final String roomId;

  /// Shown next to the dot. Off in the app bar (where space is tight); the
  /// tooltip carries the wording there.
  final bool showLabel;

  const WaConnectionIndicator({
    required this.roomId,
    this.showLabel = false,
    super.key,
  });

  @override
  State<WaConnectionIndicator> createState() => _WaConnectionIndicatorState();
}

class _WaConnectionIndicatorState extends State<WaConnectionIndicator> {
  @override
  void initState() {
    super.initState();
    // The bridge only emits state events on change, so a state missed while the
    // app was backgrounded would leave a stale dot. Re-read on open.
    // ignore: unawaited_futures
    WaMatrixBridge.instance.refreshConnStates();
  }

  @override
  Widget build(BuildContext context) {
    final bridge = WaMatrixBridge.instance;
    if (!bridge.isWaRoom(widget.roomId)) return const SizedBox.shrink();

    return ValueListenableBuilder<int>(
      valueListenable: bridge.connectionRevision,
      builder: (context, _, _) {
        final state = bridge.connStateForRoom(widget.roomId);
        final (color, label) = switch (state) {
          WaConnState.connected => (
            const Color(0xFF25D366), // WhatsApp green
            L10n.of(context).waConnected,
          ),
          WaConnState.connecting => (
            Colors.orange,
            L10n.of(context).waConnecting,
          ),
          WaConnState.disconnected => (
            Theme.of(context).colorScheme.error,
            L10n.of(context).waDisconnected,
          ),
        };

        return Tooltip(
          message: label,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  // A faint halo keeps the dot readable on both themes and on
                  // the tinted app bar background.
                  boxShadow: [
                    BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4),
                  ],
                ),
              ),
              if (widget.showLabel) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
