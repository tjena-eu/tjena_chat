// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
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

/// Settings → Messaging Bridges. Shows the two ways WhatsApp can reach tjena
/// side by side: the tjena server bridge and the user's own bridge (tjena
/// Bridge app at home); plus the Signal server bridge.
class SettingsBridgesController extends State<SettingsBridges> {
  /// Server bridges (always the shared server bots).
  List<BridgeEntry> entries = [];

  /// Own bridge (gateway status); null = none set up.
  OwnBridgeStatus? ownStatus;
  bool ownLoading = true;
  String? ownError;

  Client get client => Matrix.of(context).client;
  WhatsAppBridgeConfig get waConfig => WhatsAppBridgeConfig.of(client);

  BridgeEntry? entryFor(String id) =>
      entries.firstWhereOrNull((e) => e.def.id == id);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  Future<void> refresh() async {
    await Future.wait([_detectBridges(), _loadOwn()]);
  }

  Future<void> _detectBridges() async {
    final domain = client.userID?.domain ?? '';
    entries = kBridges
        .map((def) => BridgeEntry(def: def, botUserId: def.botUserId(domain)))
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

  Future<void> _loadOwn() async {
    setState(() => ownLoading = true);
    try {
      ownStatus = await PersonalBridgeApi.status(client, waConfig.gateway);
      ownError = null;
    } catch (e) {
      ownError = e.toString();
    }
    if (mounted) setState(() => ownLoading = false);
  }

  @override
  Widget build(BuildContext context) => SettingsBridgesView(this);
}
