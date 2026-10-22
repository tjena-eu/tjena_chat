import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../native.dart';
import 'widgets.dart';

/// Screen 2: WhatsApp login via the bridge's provisioning API (through the relay).
class WhatsAppScreen extends StatefulWidget {
  final BridgeState state;
  const WhatsAppScreen({required this.state, super.key});
  @override
  State<WhatsAppScreen> createState() => _WhatsAppScreenState();
}

class _WhatsAppScreenState extends State<WhatsAppScreen> {
  List<Map<String, dynamic>> _logins = [];
  bool _loading = false;
  String? _error;

  // Active login process
  String? _loginId;
  String? _stepId;
  String? _code; // pairing code
  String? _qr; // QR data
  String? _instructions;
  bool _waiting = false;
  bool _showAdd = false; // login form when an account is already linked
  final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!widget.state.bridgeConnected) return;
    setState(() => _loading = true);
    final r = await Native.relay('GET', '/relay/provision/v3/whoami');
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.ok) {
        _logins = ((r.json['logins'] as List?) ?? []).cast<Map<String, dynamic>>();
        _error = null;
      } else {
        _error = r.errorMessage;
      }
    });
  }

  void _resetLogin() {
    _loginId = null;
    _stepId = null;
    _code = null;
    _qr = null;
    _instructions = null;
    _waiting = false;
  }

  Future<void> _startPhone() async {
    final number = _phone.text.replaceAll(RegExp(r'[\s()-]'), '');
    if (!RegExp(r'^\+\d{7,15}$').hasMatch(number)) {
      setState(() => _error = 'Enter your number in international format, e.g. +491701234567');
      return;
    }
    setState(() {
      _error = null;
      _resetLogin();
      _waiting = true;
    });
    var r = await Native.relay('POST', '/relay/provision/v3/login/start/phone', body: {});
    if (!r.ok) return _fail(r);
    _loginId = r.json['login_id'] as String?;
    _stepId = r.json['step_id'] as String?;
    r = await Native.relay(
      'POST',
      '/relay/provision/v3/login/step/$_loginId/$_stepId/user_input',
      body: {'phone_number': number},
      timeout: const Duration(seconds: 60),
    );
    if (!r.ok) return _fail(r);
    await _handleStep(r.json);
  }

  Future<void> _startQr() async {
    setState(() {
      _error = null;
      _resetLogin();
      _waiting = true;
    });
    final r = await Native.relay('POST', '/relay/provision/v3/login/start/qr', body: {}, timeout: const Duration(seconds: 60));
    if (!r.ok) return _fail(r);
    _loginId = r.json['login_id'] as String?;
    await _handleStep(r.json);
  }

  Future<void> _handleStep(Map<String, dynamic> step) async {
    while (mounted) {
      final type = step['type'];
      _stepId = step['step_id'] as String?;
      if (step['login_id'] != null) _loginId = step['login_id'] as String;
      if (type == 'complete') {
        setState(() {
          _resetLogin();
          _showAdd = false;
          _phone.clear();
        });
        if (!mounted) return;
        toast(context, 'WhatsApp connected');
        await _load();
        return;
      }
      if (type != 'display_and_wait') {
        _fail(RelayResponse(0, '{"error":"Unexpected login step $type"}'));
        return;
      }
      final d = (step['display_and_wait'] as Map?)?.cast<String, dynamic>() ?? {};
      setState(() {
        _instructions = step['instructions'] as String?;
        if (d['type'] == 'code') {
          _code = d['data'] as String?;
        } else if (d['type'] == 'qr') {
          _qr = d['data'] as String?;
        }
      });
      // Long-poll until the user finishes in WhatsApp (or the QR refreshes).
      final r = await Native.relay(
        'POST',
        '/relay/provision/v3/login/step/$_loginId/$_stepId/display_and_wait',
        body: {},
        timeout: const Duration(minutes: 9),
      );
      if (!r.ok) return _fail(r);
      step = r.json;
    }
  }

  void _fail(RelayResponse r) {
    if (!mounted) return;
    setState(() {
      _resetLogin();
      _error = r.status == 0 ? 'Bridge not reachable: ${r.errorMessage}' : r.errorMessage;
    });
  }

  Future<void> _cancel() async {
    final id = _loginId;
    setState(_resetLogin);
    if (id != null) await Native.relay('POST', '/relay/provision/v3/login/cancel/$id', body: {});
  }

  Future<void> _logout(String id) async {
    var deleteChats = true;
    try {
      deleteChats = (await Native.options())['delete_chats_on_logout'] as bool? ?? true;
    } catch (_) {}
    if (!mounted) return;
    if (!await confirm(
        context,
        'Log out of WhatsApp?',
        deleteChats
            ? 'The bridge stops relaying this WhatsApp account and removes its chats and space from tjena. '
                'WhatsApp itself keeps all messages. (Settings → Chats & history to keep chats instead.)'
            : 'The bridge stops relaying this WhatsApp account. Its chats stay in tjena but stop updating.',
        ok: 'Log out',
        danger: true)) {
      return;
    }
    final r = await Native.relay('POST', '/relay/provision/v3/logout/$id', body: {});
    if (!r.ok && mounted) setState(() => _error = r.errorMessage);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (!widget.state.bridgeConnected) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('The bridge is not connected yet. Check the Status tab.', textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('WhatsApp', style: t.textTheme.headlineSmall),
          const SizedBox(height: 8),
          if (_loading) const LinearProgressIndicator(),
          if (_logins.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('${_logins.length} accounts linked. Each has its own chats in tjena.',
                  style: t.textTheme.bodySmall),
            ),
          for (final l in _logins) _LoginCard(login: l, onLogout: () => _logout(l['id'] as String)),
          if (_code != null) ...[
            const SizedBox(height: 16),
            Text('Your pairing code', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            Center(
              child: SelectableText(
                _code!,
                style: t.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 4, fontFamily: 'monospace'),
              ),
            ),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: _code!)),
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'On the phone with your WhatsApp account:\n'
                  '1. Open WhatsApp → Settings → Linked devices\n'
                  '2. Tap "Link a device"\n'
                  '3. Tap "Link with phone number instead"\n'
                  '4. Enter the code above',
                ),
              ),
            ),
            const LinearProgressIndicator(),
            TextButton(onPressed: _cancel, child: const Text('Cancel')),
          ] else if (_qr != null) ...[
            const SizedBox(height: 16),
            Text(_instructions ?? 'Scan with WhatsApp → Linked devices → Link a device', style: t.textTheme.titleMedium),
            const SizedBox(height: 12),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                width: 280,
                child: PrettyQrView.data(data: _qr!),
              ),
            ),
            TextButton(onPressed: _cancel, child: const Text('Cancel')),
          ] else if (_waiting) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
            TextButton(onPressed: _cancel, child: const Text('Cancel')),
          ] else ...[
            if (_logins.isNotEmpty && !_showAdd) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() => _showAdd = true),
                icon: const Icon(Icons.add),
                label: const Text('Add another WhatsApp account'),
              ),
            ],
            if (_logins.isEmpty || _showAdd) ...[
              if (_showAdd) ...[
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: Text('Add another account', style: t.textTheme.titleLarge)),
                  IconButton(onPressed: () => setState(() => _showAdd = false), icon: const Icon(Icons.close)),
                ]),
                const Text('Link a second WhatsApp number (e.g. a work phone). Its chats appear separately in tjena.'),
                const SizedBox(height: 12),
              ],
              const WarningCard(
                icon: Icons.info_outline,
                title: 'Ban risk',
                text: 'This uses an unofficial WhatsApp client. WhatsApp may restrict or ban accounts that use it.',
              ),
              const SizedBox(height: 16),
              Text('Link with your phone number', style: t.textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('You get a pairing code to type into WhatsApp. Best if WhatsApp is on this same phone.'),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number', hintText: '+491701234567'),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _startPhone, child: const Text('Get pairing code')),
              const SizedBox(height: 24),
              Text('Or scan a QR code', style: t.textTheme.titleMedium),
              const Text('Use this if WhatsApp is on another phone.'),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _startQr, child: const Text('Show QR code')),
            ],
          ],
          if (_error != null) ...[const SizedBox(height: 12), ErrorText(_error!)],
        ],
      ),
    );
  }
}

class _LoginCard extends StatelessWidget {
  final Map<String, dynamic> login;
  final VoidCallback onLogout;
  const _LoginCard({required this.login, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    final profile = (login['profile'] as Map?)?.cast<String, dynamic>() ?? {};
    final state = ((login['state'] as Map?)?['state_event'] ?? '').toString();
    final ok = state == 'CONNECTED';
    final phone = profile['phone'] as String?;
    final name = profile['name'] as String? ?? login['name'] as String?;
    return Card(
      child: ListTile(
        leading: Icon(
          ok ? Icons.check_circle : Icons.error_outline,
          color: ok ? Colors.green : (state == 'CONNECTING' || state == 'BACKFILLING' ? Colors.orange : Colors.red),
        ),
        title: Text(name ?? phone ?? '${login['id']}'),
        subtitle: Text([if (phone != null && phone != name) phone, state.toLowerCase().replaceAll('_', ' ')]
            .where((s) => s.isNotEmpty)
            .join(' · ')),
        trailing: IconButton(tooltip: 'Log out', icon: const Icon(Icons.logout), onPressed: onLogout),
      ),
    );
  }
}
