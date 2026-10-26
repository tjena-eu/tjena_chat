import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native.dart';
import 'widgets.dart';

/// "a1b2c3d4..." → "a1b2 c3d4 ...", the same grouping the tjena app uses, so
/// the two screens can be compared side by side.
String formatFingerprint(String? key) {
  if (key == null || key.isEmpty) return '—';
  final b = StringBuffer();
  for (var i = 0; i < key.length; i += 4) {
    if (i > 0) b.write(' ');
    b.write(key.substring(i, i + 4 > key.length ? key.length : i + 4));
  }
  return b.toString();
}

/// Encryption state and keys of both sides of the bridge:
/// tjena ↔ bridge (Matrix end-to-bridge encryption) and bridge ↔ WhatsApp.
/// All values come from the bridge's own database on this phone, not from the
/// server, so they can be compared with what the tjena app shows.
class SecurityScreen extends StatefulWidget {
  final BridgeState state;
  const SecurityScreen({required this.state, super.key});
  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  Map<String, dynamic>? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final info = await Native.securityInfo();
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _error = e is PlatformException ? (e.message ?? '$e') : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Security'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: info == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: ErrorText('Could not read the bridge keys: $_error'),
                    )
                  : const CircularProgressIndicator(),
            )
          : RefreshIndicator(onRefresh: _load, child: _body(context, info)),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> info) {
    final t = Theme.of(context);
    final m = (info['matrix'] as Map?)?.cast<String, dynamic>() ?? {};
    final owner = (m['owner'] as Map?)?.cast<String, dynamic>() ?? {};
    final devices = ((owner['devices'] as List?) ?? []).cast<Map>().map((d) => d.cast<String, dynamic>()).toList();
    final wa = ((info['whatsapp'] as List?) ?? []).cast<Map>().map((d) => d.cast<String, dynamic>()).toList();
    final errors = ((info['errors'] as List?) ?? []).cast<String>();
    final trustedDevices = devices.where((d) => d['cross_signed'] == true).length;
    final masterChanged = owner['master_key_changed'] == true;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // ------------------------------------------------ summary
        Padding(
          padding: const EdgeInsets.all(12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _Hop(
                  icon: Icons.phone_iphone,
                  label: 'Your tjena apps',
                  next: 'Matrix end-to-end encryption · required',
                  ok: m['ed25519'] != null,
                ),
                _Hop(
                  icon: Icons.home_outlined,
                  label: 'This bridge phone (messages are decrypted only here)',
                  next: 'WhatsApp end-to-end encryption',
                  ok: wa.isNotEmpty && wa.every((w) => w['account_signature_ok'] == true),
                ),
                const _Hop(icon: Icons.chat_outlined, label: 'WhatsApp', next: null, ok: true),
                const SizedBox(height: 8),
                Text(
                  'The tjena server only passes encrypted messages along. Compare the fingerprints below with '
                  'tjena → Settings → Messaging Bridges → Your own bridge → Security.',
                  style: t.textTheme.bodySmall,
                ),
              ]),
            ),
          ),
        ),

        // ------------------------------------------------ Matrix side
        const SectionTitle('tjena ↔ bridge'),
        const _Row(
          icon: Icons.lock_outline,
          title: 'Encryption',
          value: 'Required. The bridge refuses unencrypted chats.',
          ok: true,
        ),
        _KeyRow(
          title: 'Bridge device ${m['device_id'] ?? ''}',
          help: 'The key this bridge encrypts with',
          fingerprint: m['ed25519'] as String?,
        ),
        _KeyRow(
          title: 'Bridge identity',
          help: m['master_key'] == null
              ? 'Not recorded yet. It is published when the bridge sets up its encryption.'
              : 'Cross-signing key of ${m['bot_mxid']}',
          fingerprint: m['master_key'] as String?,
        ),
        _KeyRow(
          title: 'Your identity, as the bridge trusts it',
          help: masterChanged
              ? 'Changed since the bridge first saw it. The bridge only trusts your devices if this matches '
                  'your current tjena identity.'
              : 'Cross-signing key of ${owner['user_id']}',
          fingerprint: owner['master_key'] as String?,
          warn: masterChanged,
        ),
        _Row(
          icon: Icons.devices_outlined,
          title: 'Your devices',
          value: devices.isEmpty
              ? 'None known yet. They appear once you write to the bridge.'
              : '$trustedDevices of ${devices.length} verified. The bridge only accepts messages from, and only '
                  'shares keys with, verified (cross-signed) devices.',
          ok: devices.isNotEmpty && trustedDevices > 0,
        ),
        for (final d in devices)
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: ListTile(
              dense: true,
              leading: Icon(
                d['cross_signed'] == true ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined,
                color: d['cross_signed'] == true ? Colors.green : t.colorScheme.error,
              ),
              title: Text('${(d['name'] as String?)?.isNotEmpty == true ? d['name'] : 'Unnamed'} · ${d['device_id']}'),
              subtitle: Text(
                '${d['cross_signed'] == true ? 'Verified' : 'Not verified: messages from it are ignored'}\n'
                '${formatFingerprint(d['ed25519'] as String?)}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              isThreeLine: true,
            ),
          ),

        // ------------------------------------------------ WhatsApp side
        const SectionTitle('Bridge ↔ WhatsApp'),
        if (wa.isEmpty)
          const _Row(
            icon: Icons.link_off,
            title: 'No WhatsApp account linked',
            value: 'Link one in the WhatsApp tab.',
            ok: false,
          ),
        for (final w in wa) ...[
          _Row(
            icon: Icons.chat_outlined,
            title: '${w['phone']}${(w['push_name'] as String?)?.isNotEmpty == true ? ' · ${w['push_name']}' : ''}',
            value: 'Linked device #${w['device']}. WhatsApp encrypts end to end (Signal protocol); '
                '${w['contact_keys_known']} contact keys known.',
            ok: true,
          ),
          _Row(
            icon: w['account_signature_ok'] == true ? Icons.verified_outlined : Icons.error_outline,
            title: w['account_signature_ok'] == true ? 'Approved by your phone' : 'Approval signature invalid',
            value: w['account_signature_ok'] == true
                ? 'Your WhatsApp account key signed this bridge as a linked device.'
                : 'The stored approval from your phone does not check out. Log out and link again.',
            ok: w['account_signature_ok'] == true,
          ),
          _KeyRow(
            title: 'This linked device',
            help: 'Identity key of the bridge on WhatsApp',
            fingerprint: w['identity_key'] as String?,
          ),
          _KeyRow(
            title: 'Your WhatsApp account',
            help: 'Account key of your main phone',
            fingerprint: w['account_key'] as String?,
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'To check a single WhatsApp contact, compare the security code in WhatsApp on your phone '
            '(contact → Encryption).',
            style: t.textTheme.bodySmall,
          ),
        ),
        if (errors.isNotEmpty) ...[
          const SectionTitle('Could not read'),
          for (final e in errors) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: ErrorText(e)),
        ],
      ],
    );
  }
}

class _Hop extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? next;
  final bool ok;
  const _Hop({required this.icon, required this.label, required this.next, required this.ok});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: t.textTheme.titleSmall)),
      ]),
      if (next != null)
        Padding(
          padding: const EdgeInsets.only(left: 9, top: 2, bottom: 2),
          child: Row(children: [
            Container(width: 2, height: 28, color: ok ? Colors.green : t.colorScheme.error),
            const SizedBox(width: 14),
            Icon(ok ? Icons.lock : Icons.lock_open, size: 14, color: ok ? Colors.green : t.colorScheme.error),
            const SizedBox(width: 4),
            Expanded(child: Text(next!, style: t.textTheme.bodySmall)),
          ]),
        ),
    ]);
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final bool ok;
  const _Row({required this.icon, required this.title, required this.value, required this.ok});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: ok ? Colors.green : Theme.of(context).colorScheme.error),
        title: Text(title),
        subtitle: Text(value),
      );
}

class _KeyRow extends StatelessWidget {
  final String title;
  final String help;
  final String? fingerprint;
  final bool warn;
  const _KeyRow({required this.title, required this.help, required this.fingerprint, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListTile(
      leading: Icon(Icons.key_outlined, color: warn ? t.colorScheme.error : null),
      title: Text(title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(help, style: warn ? TextStyle(color: t.colorScheme.error) : null),
        const SizedBox(height: 4),
        SelectableText(
          formatFingerprint(fingerprint),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, letterSpacing: 0.5),
        ),
      ]),
      trailing: fingerprint == null
          ? null
          : IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: fingerprint!));
                toast(context, 'Copied');
              },
            ),
    );
  }
}
