// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'settings_bridges.dart';

class SettingsBridgesView extends StatelessWidget {
  final SettingsBridgesController controller;
  const SettingsBridgesView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messaging Bridges'),
        leading: BackButton(onPressed: () => context.go('/rooms/settings')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            tooltip: 'Re-detect bridges',
            onPressed: controller.refresh,
          ),
        ],
      ),
      body: controller.entries.isEmpty
          ? const Center(child: CircularProgressIndicator.adaptive())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Connect WhatsApp and Signal to your Matrix account. '
                    'Bridge bots are detected automatically from your homeserver.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                ...controller.entries.map(
                  (entry) => _BridgeTile(
                    entry: entry,
                    onTap: entry.availability == BridgeAvailability.unavailable
                        ? null
                        : () => context.go(
                              '/rooms/settings/bridges/${entry.def.id}',
                              extra: entry,
                            ),
                  ),
                ),
                const SizedBox(height: 16),
                if (controller.entries.every(
                  (e) => e.availability == BridgeAvailability.unavailable,
                ))
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'No bridges found',
                                style: theme.textTheme.titleSmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No mautrix bridges were detected on your homeserver. '
                            'Ask your server administrator to install mautrix-whatsapp or mautrix-signal.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _BridgeTile extends StatelessWidget {
  final BridgeEntry entry;
  final VoidCallback? onTap;
  const _BridgeTile({required this.entry, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = entry.availability == BridgeAvailability.available;
    final checking = entry.availability == BridgeAvailability.checking;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: available
                      ? entry.def.color
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  Icons.chat_outlined,
                  color: available
                      ? Colors.white
                      : theme.colorScheme.onSurfaceVariant,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.def.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.def.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),
                    _StatusBadge(availability: entry.availability),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (checking)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                )
              else if (available)
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final BridgeAvailability availability;
  const _StatusBadge({required this.availability});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (availability) {
      BridgeAvailability.checking => _badge(
          context,
          'Checking...',
          theme.colorScheme.surfaceContainerHighest,
          theme.colorScheme.onSurfaceVariant,
        ),
      BridgeAvailability.unavailable => _badge(
          context,
          'Not available on this server',
          theme.colorScheme.errorContainer,
          theme.colorScheme.onErrorContainer,
        ),
      BridgeAvailability.available => _badge(
          context,
          'Available — tap to configure',
          theme.colorScheme.primaryContainer,
          theme.colorScheme.onPrimaryContainer,
        ),
    };
  }

  Widget _badge(
    BuildContext context,
    String text,
    Color bg,
    Color fg,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
