// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

/// Links a Signal account by scanning a QR code in Signal on your phone.
class SignalLinkScreen extends StatefulWidget {
  const SignalLinkScreen({super.key});

  @override
  State<SignalLinkScreen> createState() => _SignalLinkScreenState();
}

class _SignalLinkScreenState extends State<SignalLinkScreen> {
  String? _qrUrl;
  String? _errorMsg;
  bool _loading = false;
  bool _done = false;

  StreamSubscription<BridgeEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = TjenaBridge.instance.events.listen(_onEvent);
    _startQR();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(BridgeEvent evt) {
    if (!mounted) return;
    switch (evt.type) {
      case BridgeEventType.signalQr:
        final url = evt.data['url'] as String? ?? '';
        final err = evt.data['error'] as String? ?? '';
        setState(() {
          _loading = false;
          if (err.isNotEmpty) {
            _errorMsg = err;
            _qrUrl = null;
          } else {
            _qrUrl = url;
            _errorMsg = null;
          }
        });
        break;
      case BridgeEventType.signalLinked:
        setState(() {
          _done = true;
          _loading = false;
        });
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.of(context).pop(true);
        });
        break;
      default:
        break;
    }
  }

  Future<void> _startQR() async {
    setState(() {
      _loading = true;
      _qrUrl = null;
      _errorMsg = null;
    });
    try {
      await TjenaBridge.instance.requestSignalQR();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMsg = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Link Signal')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _done
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline,
                        color: Colors.green, size: 64),
                    const SizedBox(height: 16),
                    Text('Signal linked!',
                        style: theme.textTheme.titleLarge),
                  ],
                )
              : _loading
                  ? const CircularProgressIndicator()
                  : _errorMsg != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline,
                                color: theme.colorScheme.error, size: 48),
                            const SizedBox(height: 12),
                            Text(_errorMsg!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: theme.colorScheme.error)),
                            const SizedBox(height: 16),
                            FilledButton(
                                onPressed: _startQR,
                                child: const Text('Retry')),
                          ],
                        )
                      : _qrUrl != null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Scan in Signal → Settings → Linked Devices → + Add',
                                  style: theme.textTheme.bodyMedium,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: SizedBox(
                                    width: 240,
                                    height: 240,
                                    child: PrettyQrView.data(data: _qrUrl!),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text('Waiting for scan…',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant)),
                                const SizedBox(height: 12),
                                OutlinedButton(
                                    onPressed: _startQR,
                                    child: const Text('Refresh QR')),
                              ],
                            )
                          : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
