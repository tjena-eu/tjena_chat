// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../utils/platform_infos.dart';
import '../../utils/wa_call/wa_call_service.dart';
import '../../widgets/avatar.dart';

const _callManager = MethodChannel('tjena.chat/call_manager');

String _endText(WaCall c) {
  if (c.error != null) return c.error!;
  return switch (c.endReason) {
    'hangup' => 'Call ended',
    'rejected' || 'reject' || 'busy' => 'Declined',
    'timeout' || 'no_answer' => 'No answer',
    'app_disconnected' ||
    'app_unreachable' ||
    'connection_failed' => 'Connection to your bridge phone lost',
    _ => 'Call ended',
  };
}

/// In-call screen for a WhatsApp call through the own bridge.
class WaCallPage extends StatefulWidget {
  final WaCallService service;
  final WaCall call;
  const WaCallPage({required this.service, required this.call, super.key});

  @override
  State<WaCallPage> createState() => _WaCallPageState();
}

class _WaCallPageState extends State<WaCallPage> {
  Timer? _tick;
  bool _closing = false;

  WaCall get call => widget.call;

  @override
  void initState() {
    super.initState();
    call.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && call.phase == WaCallPhase.active) setState(() {});
    });
    if (PlatformInfos.isAndroid) {
      _callManager.invokeMethod('acquireProximityWakeLock').ignore();
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (call.ended && !_closing) {
      _closing = true;
      Timer(const Duration(seconds: 2), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    call.removeListener(_changed);
    if (PlatformInfos.isAndroid) {
      _callManager.invokeMethod('releaseProximityWakeLock').ignore();
    }
    // Leaving the screen ends the call.
    if (!call.ended) widget.service.hangup(call);
    super.dispose();
  }

  String get _status {
    if (call.ended) return _endText(call);
    switch (call.phase) {
      case WaCallPhase.starting:
        return call.outgoing ? 'Connecting to your bridge…' : 'Answering…';
      case WaCallPhase.calling:
        return 'Calling on WhatsApp…';
      case WaCallPhase.ringing:
        return 'Ringing…';
      case WaCallPhase.connecting:
        return 'Connecting…';
      case WaCallPhase.active:
        final d = DateTime.now().difference(call.activeSince ?? DateTime.now());
        final m = d.inMinutes.toString().padLeft(2, '0');
        final s = (d.inSeconds % 60).toString().padLeft(2, '0');
        return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
      case WaCallPhase.ended:
        return _endText(call);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final room = call.room;
    return PopScope(
      canPop: call.ended,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.service.hangup(call);
      },
      child: Scaffold(
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 64),
              Avatar(
                mxContent: room?.avatar,
                name: call.title,
                size: 120,
                client: room?.client,
              ),
              const SizedBox(height: 24),
              Text(
                call.title,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _status,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: call.error != null ? theme.colorScheme.error : null,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                [
                  'WhatsApp call',
                  if (widget.service.accountLabel(call.account) != null)
                    'your account ${widget.service.accountLabel(call.account)}',
                  'via your bridge',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundButton(
                    icon: call.muted ? Icons.mic_off : Icons.mic_none,
                    label: call.muted ? 'Unmute' : 'Mute',
                    active: call.muted,
                    onTap: call.ended
                        ? null
                        : () => widget.service.setMuted(call, !call.muted),
                  ),
                  _RoundButton(
                    icon: Icons.call_end,
                    label: 'End',
                    color: Colors.red,
                    onTap: call.ended
                        ? () => Navigator.of(context).maybePop()
                        : () => widget.service.hangup(call),
                  ),
                  _RoundButton(
                    icon: call.speaker ? Icons.volume_up : Icons.volume_down,
                    label: 'Speaker',
                    active: call.speaker,
                    onTap: call.ended
                        ? null
                        : () => widget.service.setSpeaker(call, !call.speaker),
                  ),
                ],
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool active;
  const _RoundButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.color,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg =
        color ??
        (active ? theme.colorScheme.primary : theme.colorScheme.surface);
    final fg = color != null
        ? Colors.white
        : (active ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: fg, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: theme.textTheme.labelMedium),
      ],
    );
  }
}

/// Ringing screen for an incoming WhatsApp call.
class WaIncomingCallPage extends StatefulWidget {
  final WaCallService service;
  final WaRing ring;
  final String title;
  final Room? room;
  const WaIncomingCallPage({
    required this.service,
    required this.ring,
    required this.title,
    this.room,
    super.key,
  });

  @override
  State<WaIncomingCallPage> createState() => _WaIncomingCallPageState();
}

class _WaIncomingCallPageState extends State<WaIncomingCallPage> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.service.ringing.addListener(_ringingChanged);
    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    widget.service.ringing.removeListener(_ringingChanged);
    super.dispose();
  }

  void _ringingChanged() {
    final still = widget.service.ringing.value.any(
      (r) => r.waCallId == widget.ring.waCallId,
    );
    if (!still && !_busy && mounted) Navigator.of(context).maybePop();
  }

  Future<void> _answer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final nav = Navigator.of(context);
    try {
      final callFuture = widget.service.answer(
        widget.ring,
        title: widget.title,
        room: widget.room,
      );
      // Show the call screen right away; it follows the call's state.
      final call = widget.service.current.value;
      if (call != null) {
        unawaited(
          nav.pushReplacement(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => WaCallPage(service: widget.service, call: call),
            ),
          ),
        );
      }
      await callFuture;
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _decline() async {
    await widget.service.reject(widget.ring);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 64),
            Avatar(
              mxContent: widget.room?.avatar,
              name: widget.title,
              size: 120,
              client: widget.room?.client,
            ),
            const SizedBox(height: 24),
            Text(widget.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              [
                widget.ring.video
                    ? 'Incoming WhatsApp video call (answers with audio only)'
                    : 'Incoming WhatsApp call',
                if (widget.service.accountLabel(widget.ring.account) != null)
                  'to your account ${widget.service.accountLabel(widget.ring.account)}',
              ].join('\n'),
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _RoundButton(
                  icon: Icons.call_end,
                  label: 'Decline',
                  color: Colors.red,
                  onTap: _busy ? null : _decline,
                ),
                _RoundButton(
                  icon: Icons.call,
                  label: 'Answer',
                  color: Colors.green,
                  onTap: _busy ? null : _answer,
                ),
              ],
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

/// Starts a WhatsApp call to [room]'s contact and shows the call screen.
Future<void> startWaCall(BuildContext context, Room room) async {
  final service = WaCallService.start(room.client);
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  final future = service.dial(room);
  final call = service.current.value;
  if (call != null) {
    unawaited(
      nav.push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => WaCallPage(service: service, call: call),
        ),
      ),
    );
  }
  try {
    await future;
  } catch (e) {
    if (call == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }
}
