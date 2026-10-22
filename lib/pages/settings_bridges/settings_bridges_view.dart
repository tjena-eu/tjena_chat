// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../utils/local_bridge_control.dart';
import '../settings_bridge_local/settings_bridge_local.dart';
import 'settings_bridges.dart';

class SettingsBridgesView extends StatelessWidget {
  final SettingsBridgesController controller;
  const SettingsBridgesView(this.controller, {super.key});

  static const _waGreen = Color(0xFF25D366);
  static const _signalBlue = Color(0xFF3A76F0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    final wa = c.entryFor('whatsapp');
    final signal = c.entryFor('signal');
    final mode = c.waConfig.mode;
    final own = c.ownStatus;
    final local = c.local;
    final localOn = LocalBridgeControl.enabled;

    // --- WhatsApp: tjena server bridge
    final serverInUse = mode != 'own';
    final serverBadge = switch (wa?.availability) {
      BridgeAvailability.unavailable => const _Badge.error(
        'Not available on this server',
      ),
      BridgeAvailability.checking || null => const _Badge.neutral('Checking…'),
      _ =>
        serverInUse
            ? const _Badge.active('In use')
            : const _Badge.neutral('Not in use'),
    };

    // --- WhatsApp: own bridge
    final ownInUse = mode == 'own' && c.waConfig.ownBot != null;
    final _Badge ownBadge;
    if (c.ownLoading && own == null) {
      ownBadge = const _Badge.neutral('Checking…');
    } else if (own == null) {
      ownBadge = c.ownError != null
          ? const _Badge.error('Bridge proxy unreachable')
          : const _Badge.neutral('Not set up · tap to set up');
    } else if (ownInUse) {
      ownBadge = own.connected
          ? const _Badge.active('In use · online')
          : const _Badge.error('In use · offline');
    } else {
      ownBadge = _Badge.neutral(
        own.connected ? 'Set up · online, not in use' : 'Set up · offline',
      );
    }

    // --- WhatsApp: built-in
    final _Badge localWaBadge;
    if (!localOn) {
      localWaBadge = const _Badge.neutral('Off · turn on under Experimental');
    } else if (local == null) {
      localWaBadge = const _Badge.neutral('Checking…');
    } else if (local.waLinked == 0) {
      localWaBadge = const _Badge.neutral('On · no account linked');
    } else {
      localWaBadge = _Badge.active(
        '${local.waLinked} account${local.waLinked == 1 ? '' : 's'} linked'
        '${local.waConnected < local.waLinked ? ' · ${local.waLinked - local.waConnected} offline' : ''}',
      );
    }
    final twoWaBridges = (local?.waLinked ?? 0) > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messaging Bridges'),
        leading: BackButton(onPressed: () => context.go('/rooms/settings')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            tooltip: 'Refresh',
            onPressed: c.refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Bridges bring your WhatsApp and Signal chats into tjena. There are '
            'up to three ways for each, and they differ in where your messages '
            'are decrypted.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const _Section('WhatsApp'),
          _OptionCard(
            color: _waGreen,
            icon: Icons.cloud_outlined,
            title: 'tjena server bridge',
            lines: const [
              (Icons.devices_outlined, 'Chats on all your tjena devices'),
              (
                Icons.lock_open_outlined,
                'Messages are decrypted on the tjena server',
              ),
            ],
            badge: serverBadge,
            selected: serverInUse,
            onTap: wa == null || wa.availability != BridgeAvailability.available
                ? null
                : () =>
                      context.go('/rooms/settings/bridges/whatsapp', extra: wa),
          ),
          _OptionCard(
            color: _waGreen,
            icon: Icons.home_outlined,
            title: 'Your own bridge (tjena Bridge app)',
            lines: const [
              (Icons.devices_outlined, 'Chats on all your tjena devices'),
              (
                Icons.lock_outline,
                'Messages are only decrypted on your phone at home',
              ),
              (Icons.phone_android, 'Needs a spare Android phone at home'),
            ],
            badge: ownBadge,
            selected: ownInUse,
            recommended: true,
            onTap: () => context.go('/rooms/settings/bridges/own-whatsapp'),
          ),
          _OptionCard(
            color: _waGreen,
            icon: Icons.science_outlined,
            title: 'Built-in bridge in this app',
            subtitle: 'Experimental · being phased out',
            lines: const [
              (Icons.smartphone, 'Chats only on this phone'),
              (Icons.lock_outline, 'Messages are only decrypted on this phone'),
            ],
            badge: localWaBadge,
            selected: (local?.waLinked ?? 0) > 0,
            enabled: localOn,
            onTap: localOn
                ? () => context.go('/rooms/settings/local-bridges')
                : null,
          ),
          if (twoWaBridges)
            _Hint(
              icon: Icons.warning_amber_outlined,
              text:
                  'The built-in bridge has WhatsApp linked. If the same '
                  'WhatsApp account is also linked to the '
                  '${ownInUse ? 'your own' : 'tjena server'} bridge, every chat '
                  'appears twice. Use only one.',
            )
          else
            const _Hint(
              icon: Icons.info_outline,
              text:
                  'Switch between the server bridge and your own bridge on the '
                  '"Your own bridge" page. tjena logs WhatsApp out of the old '
                  'one first, so no chat appears twice.',
            ),
          const _Section('Signal'),
          _OptionCard(
            color: _signalBlue,
            icon: Icons.cloud_outlined,
            title: 'tjena server bridge',
            lines: const [
              (Icons.devices_outlined, 'Chats on all your tjena devices'),
              (
                Icons.lock_open_outlined,
                'Messages are decrypted on the tjena server',
              ),
            ],
            badge: switch (signal?.availability) {
              BridgeAvailability.unavailable => const _Badge.error(
                'Not available on this server',
              ),
              BridgeAvailability.available => const _Badge.neutral(
                'Available · tap to configure',
              ),
              _ => const _Badge.neutral('Checking…'),
            },
            onTap:
                signal == null ||
                    signal.availability != BridgeAvailability.available
                ? null
                : () => context.go(
                    '/rooms/settings/bridges/signal',
                    extra: signal,
                  ),
          ),
          _OptionCard(
            color: _signalBlue,
            icon: Icons.science_outlined,
            title: 'Built-in bridge in this app',
            subtitle: 'Experimental · being phased out',
            lines: const [
              (Icons.smartphone, 'Chats only on this phone'),
              (Icons.lock_outline, 'Messages are only decrypted on this phone'),
            ],
            badge: !localOn
                ? const _Badge.neutral('Off · turn on under Experimental')
                : local?.signalLinked == true
                ? (local!.signalConnected
                      ? const _Badge.active('Linked · online')
                      : const _Badge.error('Linked · offline'))
                : const _Badge.neutral('On · not linked'),
            selected: local?.signalLinked == true,
            enabled: localOn,
            onTap: localOn ? () => context.go('/rooms/settings/signal') : null,
          ),
          const _Section('Experimental'),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: SwitchListTile(
              secondary: const Icon(Icons.science_outlined),
              title: const Text('Built-in bridges'),
              subtitle: const Text(
                'Run WhatsApp and Signal inside this app, on this phone only. '
                'Being phased out in favour of your own bridge.',
              ),
              isThreeLine: true,
              value: localOn,
              onChanged: c.setLocalEnabled,
            ),
          ),
          if (localOn) const LocalBridgeBackgroundCard(),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

/// One way to bridge a network: what it is, where messages are decrypted,
/// and its current state.
class _OptionCard extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<(IconData, String)> lines;
  final _Badge badge;
  final bool selected;
  final bool enabled;
  final bool recommended;
  final VoidCallback? onTap;

  const _OptionCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.lines,
    required this.badge,
    this.subtitle,
    this.selected = false,
    this.enabled = true,
    this.recommended = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected
              ? BorderSide(color: theme.colorScheme.primary, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: enabled
                        ? color
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    icon,
                    color: enabled ? Colors.white : muted,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (recommended)
                            Text(
                              'Recommended',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.tertiary,
                          ),
                        ),
                      const SizedBox(height: 6),
                      for (final (lineIcon, text) in lines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              Icon(lineIcon, size: 14, color: muted),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  text,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      badge,
                    ],
                  ),
                ),
                if (onTap != null) Icon(Icons.chevron_right, color: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _BadgeKind { active, neutral, error }

class _Badge extends StatelessWidget {
  final String text;
  final _BadgeKind kind;
  const _Badge.active(this.text) : kind = _BadgeKind.active;
  const _Badge.neutral(this.text) : kind = _BadgeKind.neutral;
  const _Badge.error(this.text) : kind = _BadgeKind.error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (bg, fg) = switch (kind) {
      _BadgeKind.active => (cs.primaryContainer, cs.onPrimaryContainer),
      _BadgeKind.neutral => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
      _BadgeKind.error => (cs.errorContainer, cs.onErrorContainer),
    };
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
