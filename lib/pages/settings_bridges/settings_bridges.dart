// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import '../../utils/local_bridge_control.dart';
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

/// What the built-in (in-app) bridge currently has linked.
class LocalBridgeSummary {
  final int waLinked;
  final int waConnected;
  final bool signalLinked;
  final bool signalConnected;
  const LocalBridgeSummary({
    this.waLinked = 0,
    this.waConnected = 0,
    this.signalLinked = false,
    this.signalConnected = false,
  });
}

class SettingsBridges extends StatefulWidget {
  const SettingsBridges({super.key});

  @override
  SettingsBridgesController createState() => SettingsBridgesController();
}

/// Settings → Messaging Bridges. Shows the three ways WhatsApp can reach
/// tjena side by side: the tjena server bridge, the user's own bridge (tjena
/// Bridge app at home) and the experimental built-in bridge in this app.
class SettingsBridgesController extends State<SettingsBridges> {
  /// Server bridges (always the shared server bots).
  List<BridgeEntry> entries = [];

  /// Own bridge (gateway status); null = none set up.
  OwnBridgeStatus? ownStatus;
  bool ownLoading = true;
  String? ownError;

  LocalBridgeSummary? local;

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
    await Future.wait([_detectBridges(), _loadOwn(), _loadLocal()]);
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

  Future<void> _loadLocal() async {
    if (!LocalBridgeControl.enabled) {
      if (mounted) setState(() => local = null);
      return;
    }
    try {
      final accounts = await TjenaBridge.instance.listAccounts();
      final sig = await TjenaBridge.instance.getSignalState();
      local = LocalBridgeSummary(
        waLinked: accounts.where((a) => a['linked'] == true).length,
        waConnected: accounts.where((a) => a['connected'] == true).length,
        signalLinked: sig.linked,
        signalConnected: sig.connected,
      );
    } catch (e) {
      Logs().w('[Bridges] local bridge state failed: $e');
      local = const LocalBridgeSummary();
    }
    if (mounted) setState(() {});
  }

  Future<void> setLocalEnabled(bool on) async {
    if (!on && ((local?.waLinked ?? 0) > 0 || (local?.signalLinked ?? false))) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog.adaptive(
          title: const Text('Turn off built-in bridges?'),
          content: const Text(
            'Your WhatsApp/Signal accounts in the built-in bridge stay linked, '
            'but stop receiving messages until you turn this on again. '
            'Existing chats stay readable.\n\n'
            'To move for good, set up your own bridge or use the tjena server '
            'bridge, then remove the accounts here.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Turn off'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await LocalBridgeControl.setEnabled(on);
    await _loadLocal();
  }

  @override
  Widget build(BuildContext context) => SettingsBridgesView(this);
}
