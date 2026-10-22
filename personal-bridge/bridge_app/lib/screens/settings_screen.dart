import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../matrix_api.dart';
import '../native.dart';
import 'options_screen.dart';
import 'security_screen.dart';
import 'widgets.dart';

/// Screen 5: proxy URL, log export, restart, re-pair, unpair.
class SettingsScreen extends StatefulWidget {
  final BridgeState state;
  final Future<void> Function() refresh;
  const SettingsScreen({required this.state, required this.refresh, super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _guard(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editGateway() async {
    final ctrl = TextEditingController(text: widget.state.gatewayUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bridge proxy URL'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: defaultGateway)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, defaultGateway), child: const Text('Reset')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _guard(() async {
      await Native.setGatewayUrl(url);
      await widget.refresh();
    });
  }

  Future<void> _exportLogs() => _guard(() async {
        final path = await Native.exportLogs();
        await SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: 'tjena Bridge log'));
      });

  /// Fresh bridge tokens for the same slot (e.g. after another phone took over).
  Future<void> _repair() => _guard(() async {
        final s = await Native.session();
        if (s == null) throw Exception('No tjena session stored');
        final session = MatrixSession.fromJson(s);
        final bundle = await Provisioner(widget.state.gatewayUrl, session.accessToken).claim();
        await Native.updateBundle(bundle);
        await Native.restart();
        await widget.refresh();
        if (mounted) toast(context, 'This phone is now the active bridge.');
      });

  Future<void> _unpair() async {
    final ok = await confirm(
      context,
      'Remove this bridge?',
      'This logs WhatsApp out of the bridge, removes the bridge from the tjena server, signs this phone out '
          'of your tjena account and deletes all bridge data on this phone. Your chats in tjena stay readable.',
      ok: 'Remove',
      danger: true,
    );
    if (!ok) return;
    await _guard(() async {
      // 1. Log WhatsApp out (best effort; bridge may be offline).
      try {
        final r = await Native.relay('GET', '/relay/provision/v3/whoami');
        for (final l in ((r.json['logins'] as List?) ?? [])) {
          await Native.relay('POST', '/relay/provision/v3/logout/${(l as Map)['id']}', body: {});
        }
      } catch (_) {}
      // 2. Revoke at the gateway, 3. sign out the Matrix session.
      final s = await Native.session();
      if (s != null) {
        final session = MatrixSession.fromJson(s);
        try {
          await Provisioner(widget.state.gatewayUrl, session.accessToken).revoke();
        } catch (_) {}
        await logout(session);
      }
      // 4. Wipe local data.
      await Native.wipe();
      await widget.refresh();
    });
  }

  Future<void> _setNotif({String? style, bool? alerts}) => _guard(() async {
        await Native.setNotificationPrefs(
          style: style ?? widget.state.notifStyle,
          alerts: alerts ?? widget.state.notifAlerts,
        );
        await widget.refresh();
      });

  void _open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListView(
      children: [
        const SectionTitle('WhatsApp'),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Chats & history'),
          subtitle: const Text('How many old messages to copy · WhatsApp status updates'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(const OptionsScreen()),
        ),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Security'),
          subtitle: const Text('Encryption on both sides and the keys to compare'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(SecurityScreen(state: s)),
        ),
        const SectionTitle('Notifications'),
        RadioGroup<String>(
          groupValue: s.notifStyle,
          onChanged: (v) => _busy || v == null ? null : _setNotif(style: v),
          child: const Column(children: [
            RadioListTile<String>(
              value: 'normal',
              title: Text('Status notification'),
              subtitle: Text('Shows the bridge state in the status bar'),
            ),
            RadioListTile<String>(
              value: 'minimal',
              title: Text('Minimal'),
              subtitle: Text(
                'Hidden from the status bar and folded away. Android always needs a notification while the '
                'bridge runs, so it can\'t be removed completely.',
              ),
            ),
          ]),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.notification_important_outlined),
          title: const Text('Alert me about problems'),
          subtitle: const Text('When the bridge stops, or can\'t reach tjena for 10 minutes'),
          value: s.notifAlerts,
          onChanged: _busy ? null : (v) => _setNotif(alerts: v),
        ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Android notification settings'),
          subtitle: const Text('Hide or silence the bridge notifications completely in Android'),
          onTap: () => Native.openNotificationSettings(),
        ),
        const SectionTitle('Server'),
        ListTile(title: const Text('Homeserver'), subtitle: Text(s.homeserver ?? '—')),
        ListTile(title: const Text('Your account'), subtitle: Text(s.owner)),
        ListTile(
          title: const Text('Bridge proxy (advanced)'),
          subtitle: Text(s.gatewayUrl),
          trailing: const Icon(Icons.edit_outlined),
          onTap: _busy ? null : _editGateway,
        ),
        const SectionTitle('Bridge'),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Restart bridge'),
          onTap: _busy ? null : () => _guard(() async => Native.restart()),
        ),
        ListTile(
          leading: const Icon(Icons.stop_circle_outlined),
          title: const Text('Stop bridge'),
          subtitle: const Text('Stays stopped until you start it again'),
          onTap: _busy ? null : () => _guard(() async => Native.stop()),
        ),
        ListTile(
          leading: const Icon(Icons.phonelink_setup),
          title: const Text('Make this phone the active bridge'),
          subtitle: const Text('Use after another phone took over, or after restoring a backup'),
          onTap: _busy ? null : _repair,
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('Export log'),
          subtitle: const Text('Tokens, phone numbers and message text are removed'),
          onTap: _busy ? null : _exportLogs,
        ),
        const SectionTitle('Danger zone'),
        ListTile(
          leading: Icon(Icons.link_off, color: Theme.of(context).colorScheme.error),
          title: const Text('Unpair and remove bridge'),
          onTap: _busy ? null : _unpair,
        ),
        if (_busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: ErrorText(_error!)),
      ],
    );
  }
}
