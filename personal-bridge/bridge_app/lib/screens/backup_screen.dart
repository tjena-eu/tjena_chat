import 'package:flutter/material.dart';

import '../native.dart';
import 'widgets.dart';

Future<String?> _askPassphrase(BuildContext context, {required bool confirmTwice}) async {
  final a = TextEditingController();
  final b = TextEditingController();
  String? err;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('Backup passphrase'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: a, obscureText: true, decoration: const InputDecoration(labelText: 'Passphrase')),
          if (confirmTwice)
            TextField(controller: b, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat passphrase')),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: ErrorText(err!)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (a.text.length < 8) return setS(() => err = 'At least 8 characters');
              if (confirmTwice && a.text != b.text) return setS(() => err = 'Passphrases differ');
              Navigator.pop(ctx, a.text);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
}

/// Screen 6: passphrase-encrypted export of bridge DB + secrets.
class BackupScreen extends StatefulWidget {
  final BridgeState state;
  final Future<void> Function() refresh;
  const BackupScreen({required this.state, required this.refresh, super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _busy = false;
  String? _msg;

  Future<void> _export() async {
    final pass = await _askPassphrase(context, confirmTwice: true);
    if (pass == null) return;
    setState(() {
      _busy = true;
      _msg = 'The bridge pauses briefly while the backup is made…';
    });
    try {
      final ok = await Native.exportBackup(pass);
      setState(() => _msg = ok ? 'Backup saved.' : 'Backup cancelled.');
    } catch (e) {
      setState(() => _msg = 'Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await widget.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Backup', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Without a backup, losing this phone means linking WhatsApp again, and the bridge\'s encryption keys are '
          'lost (older bridged messages may then show as "unable to decrypt" on new devices).\n\n'
          'The backup contains the bridge database (your WhatsApp session) and the bridge secrets, encrypted '
          'with your passphrase. Keep it somewhere safe; anyone with the file and passphrase can take over the bridge.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _busy ? null : _export, icon: const Icon(Icons.save_alt), label: const Text('Export backup')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RestoreScreen()));
                  await widget.refresh();
                },
          icon: const Icon(Icons.restore),
          label: const Text('Restore backup'),
        ),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (_msg != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!)),
      ],
    );
  }
}

class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});
  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  bool _busy = false;
  String? _msg;

  Future<void> _restore() async {
    final ok = await confirm(
      context,
      'Restore a backup?',
      'This replaces the bridge on this phone. If the old phone is still running the same bridge, it will be '
          'stopped automatically when this one connects.',
      ok: 'Choose file',
    );
    if (!ok || !mounted) return;
    final pass = await _askPassphrase(context, confirmTwice: false);
    if (pass == null) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final done = await Native.importBackup(pass);
      setState(() => _msg = done ? 'Restored. The bridge is starting.' : 'Cancelled.');
      if (done && mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _msg = 'Restore failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Restore backup')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Pick a .tjbk backup file made by tjena Bridge and enter its passphrase.'),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _restore, child: const Text('Restore from file')),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (_msg != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!)),
      ]),
    );
  }
}
