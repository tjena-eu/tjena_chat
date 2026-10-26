// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../utils/personal_bridge.dart';

/// "a1b2c3d4…" → "a1b2 c3d4 …", the same grouping the tjena Bridge app's
/// Security screen uses, so both can be compared side by side.
String formatFingerprint(String? key) {
  if (key == null || key.isEmpty) return '—';
  final b = StringBuffer();
  for (var i = 0; i < key.length; i += 4) {
    if (i > 0) b.write(' ');
    b.write(key.substring(i, i + 4 > key.length ? key.length : i + 4));
  }
  return b.toString();
}

/// Encryption state between tjena and the user's own bridge, as this app
/// sees it: the bridge's keys (to compare with the bridge app), your own
/// identity (which the bridge must trust) and whether bridged chats are
/// encrypted.
class BridgeSecurityCard extends StatefulWidget {
  final Client client;
  final String bot;
  const BridgeSecurityCard({
    required this.client,
    required this.bot,
    super.key,
  });

  @override
  State<BridgeSecurityCard> createState() => _BridgeSecurityCardState();
}

class _BridgeSecurityCardState extends State<BridgeSecurityCard> {
  bool _loading = true;
  bool _busy = false;
  String? _error;

  Client get client => widget.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await client.updateUserDeviceKeys(additionalUsers: {widget.bot});
    } catch (e) {
      _error = 'Could not load the bridge keys: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _verify(CrossSigningKey master) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Verify your bridge?'),
        content: Text(
          'Only continue if the "Bridge identity" fingerprint in the tjena Bridge app '
          '(Settings → Security) is exactly:\n\n${formatFingerprint(master.publicKey)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('They match'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await master.setVerified(true);
    } catch (e) {
      _error = 'Could not verify: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading)
      return const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      );

    final botKeys = client.userDeviceKeys[widget.bot];
    final botMaster = botKeys?.masterKey;
    final botDevices =
        botKeys?.deviceKeys.values.where((d) => d.isValid).toList() ?? [];
    final myKeys = client.userDeviceKeys[client.userID];
    final myMaster = myKeys?.masterKey;
    final thisDevice = myKeys?.deviceKeys[client.deviceID];
    final thisDeviceTrusted = thisDevice?.crossVerified ?? false;

    final bridged = client.rooms
        .where(
          (r) =>
              r.membership == Membership.join &&
              RoomBridgeInfo.of(r)?.bridgeBot == widget.bot,
        )
        .toList();
    final encrypted = bridged.where((r) => r.encrypted).length;
    final dm = BridgeBotChat.existingDm(client, widget.bot);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Status(
          ok: encrypted == bridged.length,
          title: 'Bridged chats',
          text: bridged.isEmpty
              ? 'No bridged chats yet. Your bridge always creates them encrypted.'
              : '$encrypted of ${bridged.length} end-to-end encrypted.',
        ),
        if (dm != null)
          _Status(
            ok: dm.encrypted,
            title: 'Chat with your bridge',
            text: dm.encrypted
                ? 'End-to-end encrypted.'
                : 'Not encrypted. Tokens are never sent here.',
          ),
        _Status(
          ok: thisDeviceTrusted,
          title: 'This device',
          text: thisDeviceTrusted
              ? 'Verified. Your bridge accepts messages from it.'
              : 'Not verified. Your bridge ignores messages from unverified devices. Verify this device under '
                    'Settings → Devices.',
        ),
        const Divider(),
        Text(
          'Compare with the tjena Bridge app (Settings → Security)',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        _Fingerprint(
          title: 'Bridge identity',
          value: botMaster?.publicKey,
          badge: botMaster == null
              ? null
              : botMaster.verified
              ? 'verified by you'
              : 'not verified',
          ok: botMaster?.verified ?? false,
        ),
        for (final d in botDevices)
          _Fingerprint(
            title: 'Bridge device ${d.deviceId}',
            value: d.ed25519Key,
            badge: d.signed ? 'signed by the bridge identity' : 'not signed',
            ok: d.signed,
          ),
        if (botMaster == null && botDevices.isEmpty)
          Text(
            'No keys published yet. They appear once the bridge has started its encryption.',
            style: theme.textTheme.bodySmall,
          ),
        _Fingerprint(
          title: 'Your identity',
          value: myMaster?.publicKey,
          badge: 'the bridge must show the same key',
          ok: myMaster != null,
        ),
        _Fingerprint(
          title: 'This device ${client.deviceID ?? ''}',
          value: client.fingerprintKey,
          badge: null,
          ok: thisDeviceTrusted,
        ),
        const SizedBox(height: 8),
        if (botMaster != null && !botMaster.verified)
          FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _verify(botMaster),
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Fingerprints match: verify bridge'),
          ),
        TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Reload keys'),
        ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  final bool ok;
  final String title;
  final String text;
  const _Status({required this.ok, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        ok ? Icons.lock_outline : Icons.lock_open_outlined,
        color: ok ? Colors.green : theme.colorScheme.error,
      ),
      title: Text(title),
      subtitle: Text(text),
    );
  }
}

class _Fingerprint extends StatelessWidget {
  final String title;
  final String? value;
  final String? badge;
  final bool ok;
  const _Fingerprint({
    required this.title,
    required this.value,
    required this.badge,
    required this.ok,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        Icons.key_outlined,
        color: ok ? Colors.green : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(badge == null ? title : '$title · $badge'),
      subtitle: SelectableText(
        formatFingerprint(value),
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          letterSpacing: 0.5,
        ),
      ),
      trailing: value == null
          ? null
          : IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: value!)),
            ),
    );
  }
}
