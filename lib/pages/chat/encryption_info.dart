// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:flutter/gestures.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../utils/personal_bridge.dart';

class EncryptionInfo extends StatelessWidget {
  final Room room;

  const EncryptionInfo({super.key, required this.room});

  Future<int> _unverifiedDevices() async {
    if (!room.encrypted) return 0;
    final users = await room.requestParticipants();
    final devicesKeysLists = users
        .map((user) => room.client.userDeviceKeys[user.id])
        .nonNulls;
    final devices = devicesKeysLists.fold<List<DeviceKeys>>(
      [],
      (devices, devicesKeysList) => [
        ...devices,
        ...devicesKeysList.deviceKeys.values,
      ],
    );
    // In bridged rooms, the bridge bot's device encrypts the messages of all
    // remote contacts. The user's own bridge is trusted once it is cross-signed
    // (self_sign); it is explained by the bridge chip instead of counted here.
    final bridge = RoomBridgeInfo.of(room);
    return devices
        .where(
          (device) =>
              !(bridge != null &&
                  device.userId == bridge.bridgeBot &&
                  bridge.isOwnBridge(room.client) &&
                  device.hasValidSignatureChain(
                    verifiedByTheirMasterKey: true,
                  )) &&
              !device.verified &&
              !device.blocked &&
              !device.hasValidSignatureChain(verifiedByTheirMasterKey: true) &&
              device.encryptToDevice,
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: FluffyThemes.animationDuration,
      curve: FluffyThemes.animationCurve,
      child: FutureBuilder(
        future: _unverifiedDevices(),
        builder: (context, asyncSnapshot) {
          final unverifiedDevices = asyncSnapshot.data ?? 0;
          final bridge = RoomBridgeInfo.of(room);
          if (bridge != null && unverifiedDevices == 0) {
            return _BridgeChip(room: room, bridge: bridge);
          }
          if (unverifiedDevices == 0) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Material(
                  color: theme.colorScheme.surface.withAlpha(128),
                  borderRadius: BorderRadius.circular(
                    AppConfig.borderRadius / 3,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8.0,
                      vertical: 4.0,
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            child: Icon(Icons.lock_person_outlined, size: 13),
                          ),
                          TextSpan(text: ' '),
                          TextSpan(
                            text: L10n.of(
                              context,
                            ).countUnverifiedDevices(unverifiedDevices),
                          ),
                          TextSpan(text: ' '),
                          TextSpan(
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              decoration: TextDecoration.underline,
                              decorationColor: theme.colorScheme.primary,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () =>
                                  context.go('/rooms/${room.id}/encryption'),
                            text: 'Check',
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Shows which bridge serves this room and what that means for encryption.
class _BridgeChip extends StatelessWidget {
  final Room room;
  final RoomBridgeInfo bridge;
  const _BridgeChip({required this.room, required this.bridge});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final own = bridge.isOwnBridge(room.client);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: theme.colorScheme.surface.withAlpha(128),
          borderRadius: BorderRadius.circular(AppConfig.borderRadius / 3),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppConfig.borderRadius / 3),
            onTap: () => showDialog(
              context: context,
              builder: (ctx) => AlertDialog.adaptive(
                title: Text(bridge.describe(room.client)),
                content: Text(
                  own
                      ? 'This chat is bridged by your own bridge running on your phone at home '
                            '(${bridge.bridgeBot}). Messages from your contacts are encrypted by the bridge, '
                            'so they show as sent from the bridge\'s device. The tjena server only sees '
                            'encrypted data.'
                      : 'This chat is bridged by ${bridge.bridgeBot}. Messages from your contacts are '
                            'encrypted by the bridge\'s device, which runs where the bridge runs.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      child: Icon(
                        own ? Icons.home_outlined : Icons.swap_horiz,
                        size: 13,
                      ),
                    ),
                    TextSpan(text: ' ${bridge.describe(room.client)}'),
                  ],
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
