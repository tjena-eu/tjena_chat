// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluffychat/utils/bridge_keepalive.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

/// Screen for linking a WhatsApp account via QR code or phone number pairing.
///
/// Shows a method-selector first so only one pairing flow is ever active.
/// Starting phone-link disconnects any live QR session to prevent the QR
/// timeout from killing the phone-link connection.
class BridgeLinkScreen extends StatefulWidget {
  /// WhatsApp account to link (defaults to the primary "default" account).
  final String accountId;
  const BridgeLinkScreen({this.accountId = 'default', super.key});

  @override
  State<BridgeLinkScreen> createState() => _BridgeLinkScreenState();
}

class _BridgeLinkScreenState extends State<BridgeLinkScreen> {
  _LinkMethod? _method; // null = selector screen
  String? _qrBase64;
  String? _phoneCode;
  String? _errorMsg;
  bool _loading = false;

  // Debug panel
  final List<String> _debugEvents = [];
  String _debugLogs = '';
  bool _showDebug = false;

  final _phoneController = TextEditingController();
  StreamSubscription<BridgeEvent>? _sub;

  // When set, delete this account's existing Tjena chats + history cache right
  // before linking, so the fresh history sync rebuilds everything cleanly.
  bool _startFresh = false;

  @override
  void initState() {
    super.initState();
    _sub = TjenaBridge.instance.events.listen(_onEvent);
  }

  bool _serviceRunning = false;

  @override
  void dispose() {
    _sub?.cancel();
    _phoneController.dispose();
    _stopKeepAliveService();
    super.dispose();
  }

  /// Ensures the app is exempt from battery optimization. Aggressive OEM power
  /// management kills the WhatsApp websocket ~40s into pairing even in the
  /// foreground; the exemption is what actually keeps the socket alive long
  /// enough to enter the code. Prompts the user the first time only.
  Future<void> _ensureBatteryExemption() async {
    if (!PlatformInfos.isAndroid) return;
    try {
      // Notification permission (Android 13+) so the keep-alive service can run.
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {
      // Non-fatal — user can still grant it manually in system settings.
    }
  }

  /// Starts an Android foreground service so the WhatsApp bridge socket survives
  /// while the user switches to the WhatsApp app to enter the pairing code.
  /// Combined with the battery-optimization exemption, this is what stops the
  /// OS from killing the pairing connection mid-handshake.
  Future<void> _startKeepAliveService() async {
    if (!PlatformInfos.isAndroid) return;
    await _ensureBatteryExemption();
    if (_serviceRunning) return;
    // Shared keep-alive service — force-start it for pairing; once an account is
    // linked it stays running (managed by BridgeKeepAlive) so messages keep
    // arriving in the background.
    await BridgeKeepAlive.start();
    _serviceRunning = true;
  }

  Future<void> _stopKeepAliveService() async {
    if (!_serviceRunning) return;
    _serviceRunning = false;
    // Keep the service running if an account ended up linked; only stops if not.
    await BridgeKeepAlive.refresh();
  }

  void _onEvent(BridgeEvent evt) {
    // Ignore events for other accounts (events are tagged with account_id).
    final acc = evt.data['account_id'] as String? ?? 'default';
    if (acc != widget.accountId) return;
    if (mounted) {
      setState(() {
        _debugEvents.add(
          '${DateTime.now().toIso8601String().substring(11, 23)} ${jsonEncode(evt.data)}',
        );
        if (_debugEvents.length > 50) _debugEvents.removeAt(0);
      });
    }
    switch (evt.type) {
      case BridgeEventType.qr:
        if (mounted) setState(() { _qrBase64 = evt.data['data'] as String?; _loading = false; _errorMsg = null; });
      case BridgeEventType.phoneCode:
        if (mounted) setState(() { _phoneCode = evt.data['code'] as String?; _loading = false; _errorMsg = null; });
      case BridgeEventType.linked:
        _stopKeepAliveService();
        if (mounted) Navigator.of(context).pop(true);
      case BridgeEventType.state:
        if ((evt.data['linked'] as bool? ?? false) && mounted) {
          _stopKeepAliveService();
          Navigator.of(context).pop(true);
        }
      case BridgeEventType.pairError:
        _stopKeepAliveService();
        final msg = evt.data['error'] as String? ?? 'Pairing failed';
        if (mounted) setState(() { _errorMsg = 'Pairing failed: $msg'; _loading = false; _phoneCode = null; });
      default:
        break;
    }
  }

  void _selectMethod(_LinkMethod m) {
    setState(() {
      _method = m;
      _errorMsg = null;
      _qrBase64 = null;
      _phoneCode = null;
      _loading = false;
    });
    if (m == _LinkMethod.qr) _startQR();
  }

  void _backToSelector() {
    _stopKeepAliveService();
    setState(() {
      _method = null;
      _errorMsg = null;
      _qrBase64 = null;
      _phoneCode = null;
      _loading = false;
    });
  }

  // If "Start fresh" is checked, wipe this account's Tjena chats + history cache
  // once before linking.
  Future<void> _maybeStartFresh() async {
    if (!_startFresh) return;
    try {
      await WaMatrixBridge.instance
          .clearAccountData(Matrix.of(context).client, widget.accountId);
    } catch (_) {}
  }

  Future<void> _startQR() async {
    await _maybeStartFresh();
    setState(() { _loading = true; _qrBase64 = null; _errorMsg = null; });
    // Same OS-kill applies to the QR websocket — keep the socket alive.
    await _startKeepAliveService();
    try {
      await TjenaBridge.instance.requestQRLink(accountID: widget.accountId);
      Future.delayed(const Duration(seconds: 20), () {
        if (mounted && _loading && _qrBase64 == null) {
          setState(() {
            _errorMsg = 'No QR code received — bridge may have failed to start.';
            _loading = false;
          });
        }
      });
    } catch (e) {
      if (mounted) setState(() { _errorMsg = e.toString(); _loading = false; });
    }
  }

  Future<void> _startPhone() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) return;
    await _maybeStartFresh();
    setState(() { _loading = true; _phoneCode = null; _errorMsg = null; });
    // Start the foreground service BEFORE requesting the code so the socket
    // survives when the user switches to WhatsApp to enter it.
    await _startKeepAliveService();
    try {
      await TjenaBridge.instance.requestPhoneLink(phone, accountID: widget.accountId);
      Future.delayed(const Duration(seconds: 30), () {
        if (mounted && _loading && _phoneCode == null) {
          setState(() {
            _errorMsg = 'No pairing code received — check your number and try again.';
            _loading = false;
          });
        }
      });
    } catch (e) {
      if (mounted) setState(() { _errorMsg = e.toString(); _loading = false; });
    }
  }

  Future<void> _forceReset() async {
    setState(() { _loading = true; _errorMsg = null; _qrBase64 = null; _phoneCode = null; });
    try {
      await TjenaBridge.instance.forceReset(accountID: widget.accountId);
      _backToSelector();
    } catch (e) {
      if (mounted) setState(() { _errorMsg = e.toString(); _loading = false; });
    }
  }

  Future<void> _refreshLogs() async {
    final logs = await TjenaBridge.instance.getLogs();
    if (mounted) setState(() { _debugLogs = logs; _showDebug = true; });
  }

  bool get _isStaleCredentialError =>
      _errorMsg != null &&
      (_errorMsg!.contains('already linked') || _errorMsg!.contains('already connected'));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link WhatsApp'),
        leading: _method != null
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _backToSelector)
            : null,
      ),
      body: SafeArea(
        child: switch (_method) {
          null => _buildSelector(),
          _LinkMethod.qr => _buildQR(),
          _LinkMethod.phone => _buildPhone(),
        },
      ),
    );
  }

  Widget _buildSelector() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'How would you like to link your WhatsApp account?',
              style: TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: CheckboxListTile(
                value: _startFresh,
                onChanged: (v) => setState(() => _startFresh = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Start fresh'),
                subtitle: const Text(
                  'Delete existing Tjena chats for this account and clear the '
                  'cached history before linking. WhatsApp itself is not changed.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _selectMethod(_LinkMethod.qr),
              icon: const Icon(Icons.qr_code),
              label: const Text('Scan QR Code'),
              style: FilledButton.styleFrom(minimumSize: const Size(240, 48)),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _selectMethod(_LinkMethod.phone),
              icon: const Icon(Icons.phone),
              label: const Text('Use Phone Number'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(240, 48)),
            ),
            const SizedBox(height: 32),
            if (_loading)
              const CircularProgressIndicator()
            else
              TextButton.icon(
                onPressed: _confirmForceReset,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear linked WhatsApp data'),
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              ),
            if (_errorMsg != null) ...[
              const SizedBox(height: 12),
              Text(_errorMsg!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmForceReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear WhatsApp data?'),
        content: const Text(
          'This wipes the local WhatsApp device credentials so you can link '
          'again from scratch. It does not affect your WhatsApp account or '
          'other linked devices.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await _forceReset();
  }

  Widget _buildQR() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_errorMsg != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_errorMsg!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _startQR, child: const Text('Retry')),
              if (_isStaleCredentialError) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _forceReset, child: const Text('Clear & Re-link')),
              ],
            ],
          ),
        ),
      );
    }
    if (_qrBase64 == null) return const Center(child: Text('Waiting for QR code…'));
    final bytes = base64Decode(_qrBase64!);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Text(
            'Open WhatsApp → Settings → Linked Devices → Link a Device',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280, maxHeight: 280),
              child: Image.memory(bytes),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(onPressed: _startQR, child: const Text('Refresh QR code')),
        ],
      ),
    );
  }

  Widget _buildPhone() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Enter your WhatsApp phone number with country code (e.g. +491234567890).'),
          const SizedBox(height: 16),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+]'))],
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '+49…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _loading ? null : _startPhone,
            child: _loading
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Get pairing code'),
          ),
          if (_phoneCode != null) ...[
            const SizedBox(height: 24),
            const Text('Enter this code in WhatsApp → Settings → Linked Devices → Link with phone number:'),
            const SizedBox(height: 8),
            SelectableText(
              _phoneCode!,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 4),
            ),
            const SizedBox(height: 8),
            const Text('The code is valid for a few minutes.', style: TextStyle(color: Colors.grey)),
          ],
          if (_errorMsg != null) ...[
            const SizedBox(height: 12),
            Text(_errorMsg!, style: const TextStyle(color: Colors.red)),
            if (_isStaleCredentialError) ...[
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _forceReset, child: const Text('Clear & Re-link')),
            ],
          ],
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _refreshLogs,
            icon: const Icon(Icons.bug_report, size: 16),
            label: const Text('Show bridge logs'),
          ),
          if (_showDebug) ...[
            const SizedBox(height: 8),
            const Text('Events received:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.black87,
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  _debugEvents.isEmpty ? '(none yet)' : _debugEvents.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.greenAccent),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Bridge logs (last 100):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.black87,
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  _debugLogs.isEmpty ? '(empty)' : _debugLogs,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.lightGreenAccent),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _LinkMethod { qr, phone }
