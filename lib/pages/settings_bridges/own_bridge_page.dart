// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../../utils/personal_bridge.dart';
import '../../widgets/matrix.dart';
import 'bridge_security_card.dart';

/// Settings → Bridges → WhatsApp → "Which bridge": the shared tjena server
/// bridge or the user's own bridge running in the tjena Bridge app at home.
class OwnBridgePage extends StatefulWidget {
  const OwnBridgePage({super.key});
  @override
  State<OwnBridgePage> createState() => _OwnBridgePageState();
}

class _OwnBridgePageState extends State<OwnBridgePage> {
  OwnBridgeStatus? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _waState;
  Timer? _timer;

  Client get client => Matrix.of(context).client;
  WhatsAppBridgeConfig get cfg => WhatsAppBridgeConfig.of(client);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _timer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh(quiet: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final st = await PersonalBridgeApi.status(client, cfg.gateway);
      if (!mounted) return;
      setState(() {
        _status = st;
        _error = null;
      });
      // Remember the bot as soon as the bridge exists (setup done on the other phone).
      if (st != null && cfg.ownBot != st.botMxid) {
        await cfg.copyWith(ownBot: st.botMxid, slot: st.slot).save(client);
      }
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = 'Could not reach the bridge proxy: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

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

  Future<String?> _askPassword(String why) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Confirm with your password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(why),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'tjena password'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String text, {String ok = 'Continue', bool danger = false}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok),
          ),
        ],
      ),
    );
    return r == true;
  }

  // ---------------------------------------------------------------- setup

  Future<void> _setup() async {
    final pw = await _askPassword(
      'tjena creates a one-time sign-in code for the tjena Bridge app on your home phone. '
      'Your password is only checked by the tjena server and never shown in the QR code.',
    );
    if (pw == null || pw.isEmpty || !mounted) return;
    await _guard(() async {
      final tok = await PersonalBridgeApi.loginToken(client, password: pw);
      final link = PersonalBridgeApi.pairingLink(c: client, gateway: cfg.gateway, loginToken: tok?.token);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _PairingQrPage(
          link: link,
          expires: tok?.expires,
          hasToken: tok != null,
          gateway: cfg.gateway,
        ),
      ));
      await _refresh();
    });
  }

  Future<void> _checkWhatsApp() => _guard(() async {
        final bot = _status?.botMxid ?? cfg.ownBot;
        if (bot == null) return;
        final room = await BridgeBotChat.dm(client, bot);
        final logins = BridgeBotChat.parseLogins(await BridgeBotChat.command(room, bot, 'list-logins'));
        setState(() => _waState = logins.isEmpty
            ? 'not linked yet — link WhatsApp in the tjena Bridge app'
            : logins.map((l) => '${l.id}: ${l.state}').join(', '));
      });

  Future<void> _doublePuppet() async {
    final bot = _status?.botMxid ?? cfg.ownBot;
    if (bot == null) return;
    final pw = await _askPassword(
      'Link WhatsApp in the bridge app first.\n\n'
      'Double puppeting lets your bridge show messages you send from WhatsApp as sent by you. '
      'tjena creates a separate session "$doublePuppetDeviceName" and hands it to your bridge in your '
      'encrypted chat with it. You can log that session out any time under Settings → Devices.',
    );
    if (pw == null || pw.isEmpty) return;
    await _guard(() async {
      final token = await PersonalBridgeApi.createDoublePuppetToken(client, pw);
      final room = await BridgeBotChat.dm(client, bot);
      if (!room.encrypted) throw Exception('The chat with your bridge is not encrypted; refusing to send the token.');
      final reply = await BridgeBotChat.command(room, bot, 'login-matrix $token', redactAfter: true);
      if (mounted) {
        setState(() => _waState = reply == null ? 'No answer from the bridge' : 'Double puppeting: $reply');
      }
    });
  }

  // ---------------------------------------------------------------- switching

  Future<void> _switchTo(String mode) async {
    final serverBot = WhatsAppBridgeConfig.serverBot(client);
    final ownBot = _status?.botMxid ?? cfg.ownBot;
    if (mode == cfg.mode) return;
    if (mode == 'own') {
      if (_status == null || ownBot == null) {
        setState(() => _error = 'Set up your own bridge first.');
        return;
      }
      if (!_status!.connected) {
        setState(() => _error = 'Your bridge is offline. Switching is possible once it is online.');
        return;
      }
    }
    final from = mode == 'own' ? serverBot : ownBot;
    final ok = await _confirm(
      mode == 'own' ? 'Use your own bridge?' : 'Use the tjena server bridge?',
      'WhatsApp will be logged out of the ${mode == 'own' ? 'tjena server bridge' : 'bridge at home'} first, so your '
          'account is never bridged twice (that would duplicate every chat). Then link WhatsApp to the new bridge.',
    );
    if (!ok) return;
    await _guard(() async {
      if (from != null) {
        try {
          await BridgeBotChat.logoutAll(client, from);
        } catch (e) {
          Logs().w('[OwnBridge] logout from old bridge failed', e);
        }
      }
      await cfg.copyWith(mode: mode, ownBot: ownBot, slot: _status?.slot).save(client);
      if (from != null) await _offerArchive(from);
      if (mounted) setState(() {});
    });
  }

  Future<void> _offerArchive(String oldBot) async {
    final rooms = client.rooms
        .where((r) => r.membership == Membership.join && RoomBridgeInfo.of(r)?.bridgeBot == oldBot)
        .toList();
    if (rooms.isEmpty || !mounted) return;
    final ok = await _confirm(
      'Archive ${rooms.length} old WhatsApp chats?',
      'These chats came from the bridge you just left. Archived chats stay readable under Archive; '
          'new messages arrive in new chats from the new bridge.',
      ok: 'Archive',
    );
    if (!ok) return;
    for (final r in rooms) {
      try {
        await r.leave();
      } catch (e) {
        Logs().w('[OwnBridge] could not leave ${r.id}', e);
      }
    }
  }

  Future<void> _remove() async {
    final ok = await _confirm(
      'Remove your own bridge?',
      'WhatsApp is logged out of it and the bridge is removed from the tjena server right away. '
          'Your bridged chats stay readable. You can then uninstall tjena Bridge on the home phone.',
      ok: 'Remove',
      danger: true,
    );
    if (!ok) return;
    await _guard(() async {
      final bot = _status?.botMxid ?? cfg.ownBot;
      if (bot != null && (_status?.connected ?? false)) {
        try {
          await BridgeBotChat.logoutAll(client, bot);
        } catch (_) {}
      }
      await PersonalBridgeApi.revoke(client, cfg.gateway);
      await cfg.copyWith(mode: 'server', clearOwn: true).save(client);
      await _refresh();
    });
  }

  Future<void> _editGateway() async {
    final ctrl = TextEditingController(text: cfg.gateway);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Bridge proxy URL'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, defaultBridgeGateway), child: const Text('Reset')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (url == null || !url.startsWith('http')) return;
    await cfg.copyWith(gateway: url).save(client);
    await _refresh();
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = _status;
    final mode = cfg.mode;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp bridge'),
        leading: BackButton(onPressed: () => context.go('/rooms/settings/bridges')),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Which bridge carries your WhatsApp chats?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: mode,
            onChanged: (v) => _busy || v == null ? null : _switchTo(v),
            child: Column(children: [
              RadioListTile<String>(
                value: 'server',
                title: const Text('tjena server bridge'),
                subtitle: Text('Shared bridge (${WhatsAppBridgeConfig.serverBot(client)}). Runs on the tjena server.'),
              ),
              RadioListTile<String>(
                value: 'own',
                title: const Text('My own bridge'),
                subtitle: Text(st != null
                    ? 'Runs on your phone at home (${st.botMxid}). WhatsApp messages are only decrypted there.'
                    : 'Runs on a phone at home with the tjena Bridge app. Not set up yet.'),
              ),
            ]),
          ),
          const Divider(height: 32),
          if (_loading) const LinearProgressIndicator(),
          if (!_loading && st == null) ...[
            Text('Set up your own bridge', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'You need a spare Android phone (Android 10+) that stays at home on Wi-Fi and a charger.\n'
              '1. Install the tjena Bridge app on it.\n'
              '2. Tap "Set up" here and scan the QR code with the bridge app.\n'
              '3. Link WhatsApp in the bridge app with a pairing code.\n'
              '4. Come back here and switch to "My own bridge".',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _setup,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Set up'),
            ),
          ],
          if (st != null) ...[
            Text('Your bridge', style: theme.textTheme.titleMedium),
            Card(
              child: Column(children: [
                ListTile(
                  leading: Icon(Icons.circle, size: 14, color: st.connected ? Colors.green : theme.colorScheme.error),
                  title: Text(st.connected ? 'Online' : 'Offline'),
                  subtitle: Text(st.connected
                      ? 'Connected since ${_fmt(st.connectedSince)}'
                      : st.active
                          ? 'Last seen ${_fmt(st.lastSeen)}. Messages you send are delivered when it is back.'
                          : 'Waiting for server activation'),
                ),
                ListTile(
                  leading: const Icon(Icons.smart_toy_outlined),
                  title: Text(st.botMxid),
                  subtitle: Text('Slot ${st.slot}${st.lastEvent != null ? ' · last event ${_fmt(st.lastEvent)}' : ''}'),
                ),
                if (_waState != null)
                  ListTile(leading: const Icon(Icons.chat_outlined), title: const Text('WhatsApp'), subtitle: Text(_waState!)),
              ]),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: _busy || !st.connected ? null : _checkWhatsApp,
                icon: const Icon(Icons.radar),
                label: const Text('Check WhatsApp'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || !st.connected ? null : _doublePuppet,
                icon: const Icon(Icons.person_pin_outlined),
                label: const Text('Enable double puppeting'),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final room = await BridgeBotChat.dm(client, st.botMxid);
                        if (context.mounted) context.go('/rooms/${room.id}');
                      },
                icon: const Icon(Icons.forum_outlined),
                label: const Text('Chat with bridge'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _setup,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Pair a new bridge phone'),
              ),
            ]),
            const SizedBox(height: 8),
            Card(
              child: ExpansionTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Security'),
                subtitle: const Text('Encryption and keys to compare with the bridge app'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [BridgeSecurityCard(client: client, bot: st.botMxid)],
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: _busy ? null : _remove,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove my bridge'),
            ),
          ],
          const Divider(height: 32),
          ExpansionTile(
            title: const Text('Advanced'),
            children: [
              ListTile(
                title: const Text('Bridge proxy'),
                subtitle: Text(cfg.gateway),
                trailing: const Icon(Icons.edit_outlined),
                onTap: _editGateway,
              ),
              ListTile(
                title: const Text('Notify when offline for'),
                subtitle: Text('${cfg.offlineNotifyMinutes} minutes'),
                trailing: DropdownButton<int>(
                  value: cfg.offlineNotifyMinutes,
                  items: const [15, 30, 60, 180]
                      .map((m) => DropdownMenuItem(value: m, child: Text('$m min')))
                      .toList(),
                  onChanged: (v) async {
                    if (v == null) return;
                    await cfg.copyWith(offlineNotifyMinutes: v).save(client);
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ],
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }

  String _fmt(DateTime? t) {
    if (t == null) return 'unknown';
    final l = t.toLocal();
    final d = DateTime.now().difference(l);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }
}

/// Shows the sign-in QR for the bridge app and waits until the bridge appears.
class _PairingQrPage extends StatefulWidget {
  final String link;
  final Duration? expires;
  final bool hasToken;
  final String gateway;
  const _PairingQrPage({required this.link, required this.expires, required this.hasToken, required this.gateway});
  @override
  State<_PairingQrPage> createState() => _PairingQrPageState();
}

class _PairingQrPageState extends State<_PairingQrPage> {
  Timer? _poll;
  Timer? _tick;
  late final DateTime _start = DateTime.now();
  String _status = 'Waiting for the bridge app…';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _check());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final client = Matrix.of(context).client;
      final st = await PersonalBridgeApi.status(client, widget.gateway);
      if (st == null || !mounted) return;
      setState(() {
        if (!st.active) {
          _status = 'Bridge created. Waiting for server activation…';
        } else if (!st.connected) {
          _status = 'Bridge created. Waiting for it to connect…';
        } else {
          _status = 'Your bridge is online. Now link WhatsApp in the tjena Bridge app (WhatsApp tab).';
          _done = true;
          _poll?.cancel();
        }
      });
      await WhatsAppBridgeConfig.of(client).copyWith(ownBot: st.botMxid, slot: st.slot).save(client);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.expires == null ? null : widget.expires! - DateTime.now().difference(_start);
    final expired = left != null && left.isNegative;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in the bridge app')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('On your home phone, open tjena Bridge and tap "Sign in with tjena (scan QR)".'),
          const SizedBox(height: 16),
          if (!_done && !expired)
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                width: 280,
                child: PrettyQrView.data(data: widget.link),
              ),
            ),
          const SizedBox(height: 12),
          if (!widget.hasToken)
            const Text(
              'Your server does not allow QR sign-in, so the bridge app will ask for your tjena password instead.',
            )
          else if (left != null && !_done)
            Text(expired
                ? 'This code expired. Go back and tap Set up again.'
                : 'Code valid for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}. Single use.'),
          const SizedBox(height: 24),
          Row(children: [
            if (!_done) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            if (_done) const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 12),
            Expanded(child: Text(_status)),
          ]),
          if (_done) ...[
            const SizedBox(height: 24),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Continue')),
          ],
        ],
      ),
    );
  }
}
