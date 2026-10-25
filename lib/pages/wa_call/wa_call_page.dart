// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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
  bool _proximity = false;
  Offset? _previewPos;

  WaCall get call => widget.call;

  @override
  void initState() {
    super.initState();
    call.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && call.phase == WaCallPhase.active) setState(() {});
    });
    _syncProximity();
  }

  /// Screen off near the ear, but not while video is shown.
  void _syncProximity() {
    if (!PlatformInfos.isAndroid) return;
    final want = !call.ended && !call.showsVideo;
    if (want == _proximity) return;
    _proximity = want;
    _callManager
        .invokeMethod(
          want ? 'acquireProximityWakeLock' : 'releaseProximityWakeLock',
        )
        .ignore();
  }

  void _changed() {
    if (!mounted) return;
    _syncProximity();
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
    if (_proximity) {
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

  List<Widget> _buttons({required bool onVideo}) => [
    _RoundButton(
      icon: call.muted ? Icons.mic_off : Icons.mic_none,
      label: call.muted ? 'Unmute' : 'Mute',
      active: call.muted,
      onVideo: onVideo,
      onTap: call.ended
          ? null
          : () => widget.service.setMuted(call, !call.muted),
    ),
    if (call.videoPossible)
      _RoundButton(
        icon: call.cameraOn ? Icons.videocam : Icons.videocam_off_outlined,
        label: call.cameraOn ? 'Camera' : 'Camera off',
        active: call.cameraOn,
        onVideo: onVideo,
        onTap: call.ended
            ? null
            : () => widget.service.setCamera(call, !call.cameraOn),
      ),
    _RoundButton(
      icon: Icons.call_end,
      label: 'End',
      color: Colors.red,
      onVideo: onVideo,
      onTap: call.ended
          ? () => Navigator.of(context).maybePop()
          : () => widget.service.hangup(call),
    ),
    if (call.cameraOn)
      _RoundButton(
        icon: Icons.cameraswitch_outlined,
        label: 'Flip',
        onVideo: onVideo,
        onTap: () => widget.service.switchCamera(call),
      )
    else
      _RoundButton(
        icon: call.speaker ? Icons.volume_up : Icons.volume_down,
        label: 'Speaker',
        active: call.speaker,
        onVideo: onVideo,
        onTap: call.ended
            ? null
            : () => widget.service.setSpeaker(call, !call.speaker),
      ),
  ];

  /// "X wants to switch to video".
  Widget _upgradeBanner(ThemeData theme) => Card(
    margin: const EdgeInsets.all(16),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${call.title} wants to switch to video',
            style: theme.textTheme.titleSmall,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => widget.service.declineVideo(call),
                child: const Text('Not now'),
              ),
              FilledButton.icon(
                onPressed: () => widget.service.acceptVideo(call),
                icon: const Icon(Icons.videocam),
                label: const Text('Switch'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _videoBody(ThemeData theme) {
    final size = MediaQuery.sizeOf(context);
    const pw = 110.0, ph = 160.0;
    final pos =
        _previewPos ??
        Offset(size.width - pw - 16, MediaQuery.paddingOf(context).top + 16);
    return Stack(
      children: [
        Positioned.fill(
          child: call.peerVideo
              ? RotatedBox(
                  quarterTurns: call.peerOrientation,
                  child: RTCVideoView(
                    call.remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(
                        mxContent: call.room?.avatar,
                        name: call.title,
                        size: 96,
                        client: call.room?.client,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        call.upgradePending
                            ? 'Waiting for ${call.title} to accept video…'
                            : '${call.title}\'s camera is off',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
        ),
        // Name and time
        Positioned(
          left: 16,
          right: 140,
          top: MediaQuery.paddingOf(context).top + 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                call.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  shadows: const [Shadow(blurRadius: 4)],
                ),
              ),
              Text(
                _status,
                style: const TextStyle(
                  color: Colors.white,
                  shadows: [Shadow(blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),
        if (call.cameraOn)
          Positioned(
            left: pos.dx,
            top: pos.dy,
            child: GestureDetector(
              onPanUpdate: (d) => setState(() {
                final p = (_previewPos ?? pos) + d.delta;
                _previewPos = Offset(
                  p.dx.clamp(0, size.width - pw),
                  p.dy.clamp(0, size.height - ph),
                );
              }),
              onTap: () => widget.service.switchCamera(call),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: pw,
                  height: ph,
                  child: RTCVideoView(
                    call.localRenderer,
                    mirror: call.frontCamera,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (call.upgradeRequested) _upgradeBanner(theme),
                Padding(
                  padding: const EdgeInsets.only(bottom: 32, top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: _buttons(onVideo: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final room = call.room;
    if (call.showsVideo && !call.ended) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) widget.service.hangup(call);
        },
        child: Scaffold(backgroundColor: Colors.black, body: _videoBody(theme)),
      );
    }
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
              if (call.upgradeRequested && !call.ended) _upgradeBanner(theme),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _buttons(onVideo: false),
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

  /// Drawn over video: translucent, white text.
  final bool onVideo;
  const _RoundButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.color,
    this.active = false,
    this.onVideo = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg =
        color ??
        (onVideo
            ? (active ? Colors.white : Colors.black45)
            : (active ? theme.colorScheme.primary : theme.colorScheme.surface));
    final fg = color != null
        ? Colors.white
        : onVideo
        ? (active ? Colors.black : Colors.white)
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
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: onVideo ? Colors.white : null,
          ),
        ),
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

  Future<void> _answer({bool video = false}) async {
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
        video: video,
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
                    ? 'Incoming WhatsApp video call'
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
                if (widget.ring.video)
                  _RoundButton(
                    icon: Icons.call,
                    label: 'Audio only',
                    color: Colors.green,
                    onTap: _busy ? null : _answer,
                  ),
                _RoundButton(
                  icon: widget.ring.video ? Icons.videocam : Icons.call,
                  label: widget.ring.video ? 'Video' : 'Answer',
                  color: Colors.green,
                  onTap: _busy ? null : () => _answer(video: widget.ring.video),
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
Future<void> startWaCall(
  BuildContext context,
  Room room, {
  bool video = false,
}) async {
  final service = WaCallService.start(room.client);
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  final future = service.dial(room, video: video);
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
