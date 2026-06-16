// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class BridgeDef {
  final String id;
  final String name;
  final Color color;
  final String defaultBotLocalpart;
  final String description;
  final String docsUrl;
  final List<BridgeAction> actions;
  final List<String> connectedPatterns;
  final List<String> disconnectedPatterns;
  final String commandPrefix;
  final String pmCommand;

  const BridgeDef({
    required this.id,
    required this.name,
    required this.color,
    required this.defaultBotLocalpart,
    required this.description,
    required this.docsUrl,
    required this.actions,
    required this.connectedPatterns,
    required this.disconnectedPatterns,
    required this.commandPrefix,
    this.pmCommand = 'pm',
  });

  String botUserId(String domain) => '@$defaultBotLocalpart:$domain';
}

class BridgeAction {
  final String id;
  final String label;
  final String command;
  final IconData icon;
  final bool isDestructive;
  final bool requiresLoginWarning;
  final bool requiresPhoneNumber;

  const BridgeAction({
    required this.id,
    required this.label,
    required this.command,
    required this.icon,
    this.isDestructive = false,
    this.requiresLoginWarning = false,
    this.requiresPhoneNumber = false,
  });
}

const kBridges = [
  BridgeDef(
    id: 'whatsapp',
    name: 'WhatsApp',
    color: Color(0xFF25D366),
    defaultBotLocalpart: 'whatsappbot',
    description: 'Bridge your WhatsApp chats to Matrix via mautrix-whatsapp',
    docsUrl: 'https://docs.mau.fi/bridges/go/whatsapp/index.html',
    commandPrefix: '!wa',
    pmCommand: 'start-chat',
    connectedPatterns: ['logged in', 'you are logged in', 'connected to whatsapp'],
    disconnectedPatterns: ['not logged in', 'logged out', 'disconnected'],
    actions: [
      BridgeAction(
        id: 'list_logins',
        label: 'Check status',
        command: 'list-logins',
        icon: Icons.radar_outlined,
      ),
      BridgeAction(
        id: 'login',
        label: 'Login via QR',
        command: 'login',
        icon: Icons.qr_code_outlined,
        requiresLoginWarning: true,
      ),
      BridgeAction(
        id: 'login_phone',
        label: 'Login via phone',
        command: 'login phone',
        icon: Icons.phone_outlined,
        requiresLoginWarning: true,
        requiresPhoneNumber: true,
      ),
      BridgeAction(
        id: 'sync',
        label: 'Sync contacts',
        command: 'sync contacts',
        icon: Icons.sync_outlined,
      ),
      BridgeAction(
        id: 'logout',
        label: 'Logout',
        command: 'logout',
        icon: Icons.logout_outlined,
        isDestructive: true,
      ),
    ],
  ),
  BridgeDef(
    id: 'signal',
    name: 'Signal',
    color: Color(0xFF3A76F0),
    defaultBotLocalpart: 'signalbot',
    description: 'Bridge your Signal chats to Matrix via mautrix-signal',
    docsUrl: 'https://docs.mau.fi/bridges/python/signal/index.html',
    commandPrefix: '!signal',
    pmCommand: 'start-chat',
    connectedPatterns: ['logged in', 'you are logged in', 'connected', 'linked'],
    disconnectedPatterns: ['not logged in', 'logged out', 'disconnected', 'not linked'],
    actions: [
      BridgeAction(
        id: 'list_logins',
        label: 'Check status',
        command: 'list-logins',
        icon: Icons.radar_outlined,
      ),
      BridgeAction(
        id: 'login',
        label: 'Login',
        command: 'login',
        icon: Icons.link_outlined,
        requiresLoginWarning: true,
      ),
      BridgeAction(
        id: 'sync',
        label: 'Sync contacts',
        command: 'sync contacts',
        icon: Icons.sync_outlined,
      ),
      BridgeAction(
        id: 'logout',
        label: 'Logout',
        command: 'logout',
        icon: Icons.logout_outlined,
        isDestructive: true,
      ),
    ],
  ),
];
