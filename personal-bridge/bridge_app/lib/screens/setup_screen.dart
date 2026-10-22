import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import '../matrix_api.dart';
import '../native.dart';
import 'backup_screen.dart';
import 'widgets.dart';

/// Screen 1: sign in with the tjena account, get a bridge slot, start.
class SetupScreen extends StatefulWidget {
  final Future<void> Function() onDone;
  const SetupScreen({required this.onDone, super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _acceptedRisk = false;
  bool _busy = false;
  String? _progress;
  String? _error;
  bool _showManual = false;
  bool _showAdvanced = false;
  final _hs = TextEditingController(text: defaultHomeserver);
  final _gw = TextEditingController(text: defaultGateway);
  final _user = TextEditingController();
  final _pass = TextEditingController();

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _QrScanPage()));
    if (raw == null) return;
    final link = PairingLink.parse(raw);
    if (link == null) {
      setState(() => _error = 'This is not a tjena bridge QR code. Open tjena → Settings → Bridges → WhatsApp → My own bridge.');
      return;
    }
    _hs.text = link.homeserver;
    _gw.text = link.gateway;
    if (link.user != null) _user.text = link.user!;
    if (link.loginToken == null) {
      setState(() {
        _showManual = true;
        _error = 'Your server does not support QR sign-in. Enter your tjena password below instead.';
      });
      return;
    }
    await _run(() => login(homeserver: link.homeserver, loginToken: link.loginToken));
  }

  Future<void> _manual() async {
    final user = _user.text.trim();
    if (user.isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your tjena username and password.');
      return;
    }
    await _run(() => login(homeserver: _hs.text.trim(), user: user, password: _pass.text));
  }

  Future<void> _run(Future<MatrixSession> Function() doLogin) async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Signing in…';
    });
    MatrixSession? session;
    try {
      session = await doLogin();
      setState(() => _progress = 'Signed in as ${session!.userId}. Requesting your bridge…');
      final prov = Provisioner(_gw.text.trim(), session.accessToken);
      var bundle = await prov.claim();
      // A slot is usable once Synapse has loaded it. With the slot pool this is
      // normally immediate; otherwise wait for the admin's planned restart.
      while (bundle['active'] != true) {
        setState(() => _progress = 'Waiting for server activation…\nThis bridge slot becomes usable after the server\'s next planned restart. You can leave this screen open.');
        await Future.delayed(const Duration(seconds: 15));
        final st = await prov.status();
        if (st != null && st['active'] == true) bundle['active'] = true;
        if (!mounted) return;
      }
      setState(() => _progress = 'Configuring the bridge…');
      await Native.saveSetup(bundle: bundle, session: session.toJson(), gateway: _gw.text.trim());
      await Native.start();
      _pass.clear();
      await widget.onDone();
    } on ApiException catch (e) {
      if (session != null && e.status != 0) await logout(session);
      setState(() => _error = e.status == 503
          ? 'The server has no free bridge slots right now. Ask the tjena admin to add more.'
          : e.status == 429
              ? 'Too many setup attempts. Please try again in an hour.'
              : 'Setup failed: ${e.message}');
    } catch (e) {
      setState(() => _error = 'Setup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Set up your WhatsApp bridge')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('This phone will run your personal WhatsApp bridge for tjena.', style: t.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Keep it at home, on Wi-Fi and on a charger. Your WhatsApp messages are only decrypted on this phone '
            'and on your own tjena devices — the tjena server only relays encrypted data.',
          ),
          const SizedBox(height: 16),
          const WarningCard(
            title: 'Unofficial WhatsApp client',
            text: 'The bridge connects to WhatsApp as a "linked device" using an unofficial client. '
                'WhatsApp may restrict or ban accounts that use unofficial clients. Use at your own risk.',
          ),
          CheckboxListTile(
            value: _acceptedRisk,
            onChanged: _busy ? null : (v) => setState(() => _acceptedRisk = v ?? false),
            title: const Text('I understand the risk'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(_progress ?? ''),
          ] else ...[
            FilledButton.icon(
              onPressed: _acceptedRisk ? _scan : null,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Sign in with tjena (scan QR)'),
            ),
            const SizedBox(height: 4),
            Text(
              'In the tjena app: Settings → Bridges → WhatsApp → My own bridge → Set up. '
              'Your password is never typed on this phone.',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _showManual = !_showManual),
              child: Text(_showManual ? 'Hide password sign-in' : 'Sign in with username and password instead'),
            ),
            if (_showManual) ...[
              TextField(controller: _user, decoration: const InputDecoration(labelText: 'tjena username or @user:tjena.eu')),
              TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: _acceptedRisk ? _manual : null, child: const Text('Sign in')),
            ],
            TextButton(
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              child: const Text('Advanced'),
            ),
            if (_showAdvanced) ...[
              TextField(controller: _hs, decoration: const InputDecoration(labelText: 'Homeserver (for sign-in)')),
              TextField(controller: _gw, decoration: const InputDecoration(labelText: 'Bridge proxy (gateway)')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RestoreScreen()));
                  await widget.onDone();
                },
                icon: const Icon(Icons.restore),
                label: const Text('Restore from a backup'),
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            ErrorText(_error!),
          ],
        ],
      ),
    );
  }
}

class _QrScanPage extends StatefulWidget {
  const _QrScanPage();
  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final _key = GlobalKey(debugLabel: 'QR');
  QRViewController? _controller;
  StreamSubscription? _sub;

  @override
  void reassemble() {
    super.reassemble();
    if (Platform.isAndroid) _controller?.pauseCamera();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the QR code from tjena')),
      body: QRView(
        key: _key,
        onQRViewCreated: (c) {
          _controller = c;
          final nav = Navigator.of(context);
          // Scanner can start paused on Android.
          c.pauseCamera();
          c.resumeCamera();
          _sub = c.scannedDataStream.listen((d) {
            final code = d.code;
            if (code == null || !code.startsWith('tjena-bridge://')) return;
            _sub?.cancel();
            if (mounted) nav.pop(code);
          });
        },
        overlay: QrScannerOverlayShape(
          borderColor: Theme.of(context).colorScheme.primary,
          borderRadius: 10,
          borderLength: 30,
          borderWidth: 8,
        ),
      ),
    );
  }
}
