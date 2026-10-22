// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../utils/personal_bridge.dart';
import '../../widgets/matrix.dart';
import 'bridge_definition.dart';
import 'settings_bridges_view.dart';

enum BridgeAvailability { checking, unavailable, available }

class BridgeEntry {
  final BridgeDef def;
  final String botUserId;
  BridgeAvailability availability;
  Room? dmRoom;
  final bool isOwnBridge;

  BridgeEntry({
    required this.def,
    required this.botUserId,
    this.isOwnBridge = false,
    this.availability = BridgeAvailability.checking,
    this.dmRoom,
  });
}

class SettingsBridges extends StatefulWidget {
  const SettingsBridges({super.key});

  @override
  SettingsBridgesController createState() => SettingsBridgesController();
}

class SettingsBridgesController extends State<SettingsBridges> {
  List<BridgeEntry> entries = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _detectBridges());
  }

  Future<void> _detectBridges() async {
    final client = Matrix.of(context).client;
    final domain = client.userID?.domain ?? '';

    // WhatsApp may use the user's own bridge (tjena Bridge app at home).
    final waConfig = WhatsAppBridgeConfig.of(client);
    entries = kBridges
        .map(
          (def) => BridgeEntry(
            def: def,
            botUserId: def.id == 'whatsapp' && waConfig.usesOwn
                ? waConfig.ownBot!
                : def.botUserId(domain),
            isOwnBridge: def.id == 'whatsapp' && waConfig.usesOwn,
          ),
        )
        .toList();
    if (mounted) setState(() {});

    for (final entry in entries) {
      try {
        await client.getUserProfile(entry.botUserId);
        entry.dmRoom = client.rooms.firstWhereOrNull(
          (r) => r.isDirectChat && r.directChatMatrixID == entry.botUserId,
        );
        entry.availability = BridgeAvailability.available;
      } catch (_) {
        entry.availability = BridgeAvailability.unavailable;
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> refresh() => _detectBridges();

  @override
  Widget build(BuildContext context) => SettingsBridgesView(this);
}
