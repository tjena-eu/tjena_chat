// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

class VideoRenderer extends StatefulWidget {
  final WrappedMediaStream? stream;
  final bool mirror;
  final RTCVideoViewObjectFit fit;

  const VideoRenderer(
    this.stream, {
    this.mirror = false,
    this.fit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _VideoRendererState();
}

class _VideoRendererState extends State<VideoRenderer> {
  RTCVideoRenderer? _renderer;
  bool _rendererReady = false;
  MediaStream? get mediaStream => widget.stream?.stream;
  StreamSubscription? _streamChangeSubscription;

  Future<RTCVideoRenderer> _initializeRenderer() async {
    _renderer ??= RTCVideoRenderer();
    await _renderer!.initialize();
    _renderer!.srcObject = mediaStream;
    return _renderer!;
  }

  void disposeRenderer() {
    try {
      _renderer?.srcObject = null;
      _renderer?.dispose();
      _renderer = null;
      // ignore: empty_catches
    } catch (e) {}
  }

  @override
  void initState() {
    _subscribeToStreamChanges();
    setupRenderer();
    super.initState();
  }

  void _subscribeToStreamChanges() {
    _streamChangeSubscription?.cancel();
    _streamChangeSubscription = widget.stream?.onStreamChanged.stream.listen((
      stream,
    ) {
      if (!mounted) return;
      setState(() {
        _renderer?.srcObject = stream;
      });
    });
  }

  @override
  void didUpdateWidget(VideoRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the dialer swaps the wrapped stream on this slot (e.g. the main view
    // switching from the local self-view to the remote stream once it arrives),
    // Flutter reuses this State, so we must re-point the renderer at the new
    // stream — otherwise it keeps showing the old (local) video.
    if (!identical(oldWidget.stream, widget.stream)) {
      _subscribeToStreamChanges();
      _renderer?.srcObject = mediaStream;
    }
  }

  Future<void> setupRenderer() async {
    await _initializeRenderer();
    setState(() => _rendererReady = true);
  }

  @override
  void dispose() {
    _streamChangeSubscription?.cancel();
    disposeRenderer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_rendererReady
      ? Container()
      : Builder(
          key: widget.key,
          builder: (ctx) {
            return RTCVideoView(
              _renderer!,
              mirror: widget.mirror,
              filterQuality: FilterQuality.medium,
              objectFit: widget.fit,
              placeholderBuilder: (_) =>
                  Container(color: Colors.white.withAlpha(45)),
            );
          },
        );
}
