import 'dart:async';

import 'package:flutter/material.dart';

import '../native.dart';
import 'widgets.dart';

/// WhatsApp calls overview: on/off and the state of each account's calls
/// device. Setting up calls for an account is done in the WhatsApp tab.
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});
  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  bool _enabled = false;
  Map<String, dynamic>? _status; // daemon /status, null = not running
  String? _error;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final st = await Native.state();
      final r = await Native.wacall('GET', '/status', timeout: const Duration(seconds: 4));
      if (!mounted) return;
      setState(() {
        _enabled = st.callsEnabled;
        _status = r.ok ? r.json : null;
      });
    } catch (_) {}
  }

  Future<void> _setEnabled(bool on) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Native.setCallsEnabled(on);
      setState(() => _enabled = on);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wa = (_status?['whatsapp'] as Map?)?.cast<String, dynamic>();
    final gw = (_status?['gateway'] as Map?)?.cast<String, dynamic>();
    final accounts = ((wa?['accounts'] as List?) ?? []).cast<Map>();
    final running = _status != null;

    return Scaffold(
      appBar: AppBar(title: Text('WhatsApp calls${running ? ' · v${_status!['version']}' : ''}')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          SwitchListTile(
            value: _enabled,
            onChanged: _busy ? null : _setEnabled,
            title: const Text('Calls from tjena'),
            subtitle: const Text(
              'Call your WhatsApp contacts from tjena and answer their calls there. Each WhatsApp '
              'account gets a second linked device on this phone, used only for calls. '
              'Set it up per account in the WhatsApp tab.',
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(16), child: ErrorText(_error!)),
          if (_enabled && !running)
            const ListTile(
              leading: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              title: Text('Starting…'),
              subtitle: Text('The bridge must be running.'),
            ),
          if (running) ...[
            const SectionTitle('Status'),
            StatusRow(
              'Reachable from tjena',
              gw?['connected'] == true ? 'Connected to the tjena server' : (gw?['error'] as String? ?? 'Connecting…'),
              gw?['connected'] == true ? Health.ok : Health.warn,
            ),
            if (accounts.isEmpty)
              const StatusRow('Accounts with calls', 'None yet. WhatsApp tab → an account → Calls → Set up', Health.warn),
            for (final a in accounts)
              StatusRow(
                'WhatsApp +${a['phone']}',
                a['connected'] == true ? 'Calls device online' : ((a['last_error'] as String?) ?? 'Connecting…'),
                a['connected'] == true ? Health.ok : Health.warn,
              ),
            if ((_status!['active_calls'] as int? ?? 0) > 0)
              StatusRow('Calls now', '${_status!['active_calls']} active', Health.ok),
          ],
          const SectionTitle('About'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'A call from tjena goes out from the WhatsApp account the chat belongs to; an incoming call '
              'shows up in that account\'s chat. Audio goes directly between tjena and this phone '
              '(encrypted WebRTC, through the tjena TURN server if needed), and from this phone to '
              'WhatsApp with WhatsApp\'s own encryption. The tjena server only passes on call setup '
              'messages. WhatsApp calls use meowcaller (MIT licence), an independent implementation '
              'not made by WhatsApp; WhatsApp may change its call protocol at any time.',
            ),
          ),
        ],
      ),
    );
  }
}
