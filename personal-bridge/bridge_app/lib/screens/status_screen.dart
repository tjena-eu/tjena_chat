import 'dart:async';

import 'package:flutter/material.dart';

import '../native.dart';
import 'security_screen.dart';
import 'widgets.dart';

/// Screen 3: is everything running?
class StatusScreen extends StatefulWidget {
  final BridgeState state;
  final Future<void> Function() refresh;
  const StatusScreen({required this.state, required this.refresh, super.key});
  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  String _wa = 'checking…';
  Health _waHealth = Health.unknown;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _checkWhatsApp();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _checkWhatsApp());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkWhatsApp() async {
    if (!widget.state.bridgeConnected) {
      setState(() {
        _wa = 'unknown (bridge not connected)';
        _waHealth = Health.unknown;
      });
      return;
    }
    final r = await Native.relay('GET', '/relay/provision/v3/whoami');
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _wa = 'unknown (${r.errorMessage})';
        _waHealth = Health.unknown;
      });
      return;
    }
    final logins = (r.json['logins'] as List?) ?? [];
    if (logins.isEmpty) {
      setState(() {
        _wa = 'not logged in — open the WhatsApp tab';
        _waHealth = Health.warn;
      });
      return;
    }
    Health health(String st) =>
        st == 'CONNECTED' ? Health.ok : (st == 'CONNECTING' || st == 'BACKFILLING' ? Health.warn : Health.bad);
    final parts = <String>[];
    var worst = Health.ok;
    for (final raw in logins) {
      final l = (raw as Map).cast<String, dynamic>();
      final st = ((l['state'] as Map?)?['state_event'] ?? l['state_event'] ?? '?').toString();
      parts.add('${l['name'] ?? l['id']}: $st');
      final h = health(st);
      if (h.index > worst.index) worst = h;
    }
    setState(() {
      _wa = parts.join('\n');
      _waHealth = worst;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final running = s.serviceState == 'running';
    final procText = switch (s.serviceState) {
      'running' => 'running',
      'starting' => 'starting…',
      'restarting' => s.serviceDetail ?? 'restarting…',
      'halted' => 'stopped: ${s.serviceDetail ?? ''}',
      'error' => 'error: ${s.serviceDetail ?? ''}',
      _ => s.enabled ? s.serviceState : 'stopped',
    };
    return RefreshIndicator(
      onRefresh: () async {
        await widget.refresh();
        await _checkWhatsApp();
      },
      child: ListView(
        children: [
          ListTile(
            title: Text('Bridge for ${s.owner}', style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text('Bot ${s.botMxid} · slot ${s.slot}'),
          ),
          if (!s.binariesPresent)
            const Padding(
              padding: EdgeInsets.all(12),
              child: WarningCard(title: 'Bridge binary missing', text: 'This app build does not contain the bridge. Reinstall the app.'),
            ),
          if (s.revoked || s.serviceState == 'halted')
            Padding(
              padding: const EdgeInsets.all(12),
              child: WarningCard(
                title: 'Bridge stopped',
                text: s.serviceDetail ??
                    'The server no longer accepts this bridge. Set it up again from the tjena app (Settings → Unpair, then set up).',
              ),
            ),
          const SectionTitle('Connection'),
          StatusRow('Bridge process', procText, running ? Health.ok : (s.enabled ? Health.warn : Health.bad)),
          StatusRow(
            'Connection to tjena',
            s.upstreamConnected ? 'connected' : (s.upstreamError ?? 'not connected'),
            s.upstreamConnected ? Health.ok : Health.bad,
          ),
          StatusRow('WhatsApp', _wa, _waHealth),
          StatusRow('Last event from tjena', ago(s.lastEvent), s.lastEvent == null ? Health.unknown : Health.ok),
          ListTile(
            dense: true,
            leading: const Icon(Icons.lock, color: Colors.green, size: 16),
            title: const Text('Encryption'),
            subtitle: const Text('Required on both sides'),
            trailing: TextButton(
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => SecurityScreen(state: s))),
              child: const Text('View keys'),
            ),
          ),
          const SectionTitle('This phone'),
          StatusRow(
            'Battery optimisation',
            s.batteryUnrestricted ? 'unrestricted (good)' : 'restricted — Android may stop the bridge',
            s.batteryUnrestricted ? Health.ok : Health.warn,
            action: s.batteryUnrestricted
                ? null
                : TextButton(onPressed: Native.requestBatteryExemption, child: const Text('Fix')),
          ),
          StatusRow('Bridge version', s.bridgeVersion, Health.unknown),
          if (s.lastExit != null) StatusRow('Last restart', s.lastExit!, Health.unknown),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (!s.enabled || s.serviceState == 'halted' || s.serviceState == 'stopped')
                FilledButton.icon(
                  onPressed: () async {
                    await Native.start();
                    await widget.refresh();
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start bridge'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () async {
                    await Native.restart();
                    await widget.refresh();
                  },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Restart'),
                ),
            ]),
          ),
          ExpansionTile(
            title: const Text('Recent log (no message content)'),
            children: [
              FutureBuilder<String>(
                future: Native.recentLog(),
                builder: (_, snap) => Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    (snap.data ?? '').split('\n').reversed.take(60).join('\n'),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
