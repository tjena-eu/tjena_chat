import 'package:flutter/material.dart';

import '../native.dart';
import 'widgets.dart';

/// Screen 4: who may use this bridge. Owner is always admin.
class PermissionsScreen extends StatefulWidget {
  final BridgeState state;
  final Future<void> Function() refresh;
  const PermissionsScreen({required this.state, required this.refresh, super.key});
  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _saving = false;

  static final _mxid = RegExp(r'^@[a-z0-9._=/+-]+:[a-zA-Z0-9.-]+(:\d+)?$');

  Future<void> _save(List<String> users) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await Native.setExtraUsers(users);
      await widget.refresh();
      if (mounted) toast(context, 'Saved. The bridge restarts.');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _add() async {
    final u = _ctrl.text.trim();
    if (!_mxid.hasMatch(u)) {
      setState(() => _error = 'Enter a full Matrix ID like @friend:tjena.eu. Wildcards and whole domains are not allowed.');
      return;
    }
    if (u == widget.state.owner || widget.state.extraUsers.contains(u)) {
      setState(() => _error = 'Already listed.');
      return;
    }
    final ok = await confirm(
      context,
      'Let $u use your bridge?',
      'They can log their own WhatsApp account into this bridge. Their WhatsApp messages would then be '
          'decrypted on THIS phone — you, as the phone\'s owner, could technically read them. '
          'Only do this for people who trust you with that. It is better if they run their own bridge.',
      ok: 'Allow',
      danger: true,
    );
    if (!ok) return;
    _ctrl.clear();
    await _save([...widget.state.extraUsers, u]);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Who can use this bridge', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.verified_user),
            title: Text(s.owner),
            subtitle: const Text('Owner · admin (fixed)'),
          ),
        ),
        for (final u in s.extraUsers)
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(u),
              subtitle: const Text('User'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: _saving ? null : () => _save(s.extraUsers.where((x) => x != u).toList()),
              ),
            ),
          ),
        const SizedBox(height: 16),
        const WarningCard(
          title: 'Sharing is discouraged',
          text: 'Anyone you add has their WhatsApp plaintext pass through this phone. '
              'Relay mode is off: people not listed here cannot use the bridge at all.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctrl,
          decoration: const InputDecoration(labelText: 'Add user (full Matrix ID)', hintText: '@friend:tjena.eu'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(onPressed: _saving ? null : _add, child: const Text('Add user')),
        if (_saving) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: ErrorText(_error!)),
      ],
    );
  }
}
