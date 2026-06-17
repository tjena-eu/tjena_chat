// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:core';

import 'package:fluffychat/pages/dialer/dialer.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc_impl;
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;

import '../../utils/voip/user_media_manager.dart';
import '../widgets/matrix.dart';

class VoipPlugin with WidgetsBindingObserver implements WebRTCDelegate {
  final MatrixState matrix;
  Client get client => matrix.client;
  VoipPlugin(this.matrix) {
    Logs().i('[VOIP] VoipPlugin created for ${client.userID}');
    voip = VoIP(client, this);
    if (!kIsWeb) {
      final wb = WidgetsBinding.instance;
      wb.addObserver(this);
      didChangeAppLifecycleState(wb.lifecycleState);
    }
  }
  bool background = false;
  bool speakerOn = false;
  late VoIP voip;
  OverlayEntry? overlayEntry;
  BuildContext? context;

  @override
  void didChangeAppLifecycleState(AppLifecycleState? state) {
    background =
        (state == AppLifecycleState.detached ||
        state == AppLifecycleState.paused);
  }

  void addCallingOverlay(String callId, CallSession call) {
    final context = this.context;
    if (context == null || !context.mounted) {
      throw ('addCallingOverlay because of missing context', context);
    }

    if (overlayEntry != null) {
      Logs().e('[VOIP] addCallingOverlay: The call session already exists?');
      overlayEntry!.remove();
    }

    overlayEntry = OverlayEntry(
      builder: (_) => Calling(
        context: context,
        client: client,
        callId: callId,
        call: call,
        onClear: () {
          overlayEntry?.remove();
          overlayEntry = null;
        },
      ),
    );
    Overlay.of(context).insert(overlayEntry!);
  }

  @override
  MediaDevices get mediaDevices => webrtc_impl.navigator.mediaDevices;

  @override
  bool get isWeb => kIsWeb;

  @override
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) async {
    // The Matrix SDK passes ICE servers from the homeserver's /voip/turnServer
    // endpoint as { username, credential, urls: [<list>] }. flutter_webrtc's
    // Android code handles the List form correctly (credentials checked before
    // use), so we keep the SDK's servers untouched and only guarantee a STUN
    // fallback so candidate gathering never starts empty.
    final servers =
        (configuration['iceServers'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        <Map<String, dynamic>>[];

    final hasStun = servers.any((s) {
      final urls = s['urls'] ?? s['url'];
      final list = urls is List ? urls : [urls];
      return list.any((u) => u is String && u.startsWith('stun:'));
    });
    if (!hasStun) {
      servers.add({
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ],
      });
    }

    final pc = await webrtc_impl.createPeerConnection(
      {...configuration, 'iceServers': servers},
      constraints,
    );

    // onConnectionState is not overwritten by the SDK, so this survives.
    // On connect, recover the remote stream if onTrack failed to deliver one.
    pc.onConnectionState = (state) async {
      if (state ==
          webrtc_impl.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        await _recoverRemoteStreamIfMissing(pc);
      }
    };

    return pc;
  }

  /// On Android, flutter_webrtc's `onTrack` sometimes never fires even though
  /// the remote tracks are present on the RtpReceivers. When that happens the
  /// matrix SDK never registers a remote stream, so no remote video renders
  /// (audio still plays, routed natively). As a fallback, once the connection
  /// is established we reconstruct a remote MediaStream from the receiver tracks
  /// and hand it to the SDK so the dialer can render it normally.
  Future<void> _recoverRemoteStreamIfMissing(
    webrtc_impl.RTCPeerConnection pc,
  ) async {
    try {
      final cid = voip.currentCID;
      if (cid == null) return;
      final call = voip.calls[cid];
      if (call == null) return;

      // If onTrack already delivered a remote stream, do nothing.
      if (call.getRemoteStreams.isNotEmpty) return;

      final receivers = await pc.getReceivers();
      final tracks = receivers
          .map((r) => r.track)
          .whereType<webrtc_impl.MediaStreamTrack>()
          .toList();
      if (tracks.isEmpty) return;

      final remoteStream = await webrtc_impl.createLocalMediaStream(
        'tjena_reconstructed_remote',
      );
      for (final track in tracks) {
        await remoteStream.addTrack(track);
      }
      await call.addReconstructedRemoteStream(remoteStream);
      Logs().i('[VOIP] recovered remote stream from receivers (onTrack missed)');
    } catch (e, s) {
      Logs().e('[VOIP] remote stream recovery failed', e, s);
    }
  }

  Future<bool> get hasCallingAccount async => false;

  @override
  Future<void> playRingtone() async {
    // playRingtone is called before initWithInvite (which calls getUserMedia).
    // On Android, getUserMedia is blocked in background without a foreground context.
    // Wake the screen and bring the app forward NOW so the mic is accessible.
    if (PlatformInfos.isAndroid && background) {
      try {
        final wasForeground = await FlutterForegroundTask.isAppOnForeground;
        await matrix.store.setString(
          'wasForeground',
          wasForeground == true ? 'true' : 'false',
        );
        FlutterForegroundTask.setOnLockScreenVisibility(true);
        FlutterForegroundTask.wakeUpScreen();
        FlutterForegroundTask.launchApp();
        Logs().i('[VOIP] playRingtone: woke screen for incoming call');
      } catch (e) {
        Logs().e('[VOIP] playRingtone: foreground launch failed $e');
      }
    }
    if (!background && !await hasCallingAccount) {
      try {
        await UserMediaManager().startRingingTone();
      } catch (_) {}
    }
  }

  @override
  Future<void> stopRingtone() async {
    if (!background && !await hasCallingAccount) {
      try {
        await UserMediaManager().stopRingingTone();
      } catch (_) {}
    }
  }

  @override
  Future<void> handleNewCall(CallSession call) async {
    Logs().i('[VOIP] handleNewCall: ${call.callId} dir=${call.direction}');
    // Foreground launch already done in playRingtone for incoming calls.
    // For outgoing calls (no ringtone played), do it here.
    if (PlatformInfos.isAndroid && call.direction == CallDirection.kOutgoing) {
      try {
        final wasForeground = await FlutterForegroundTask.isAppOnForeground;
        await matrix.store.setString(
          'wasForeground',
          wasForeground == true ? 'true' : 'false',
        );
        FlutterForegroundTask.setOnLockScreenVisibility(true);
        FlutterForegroundTask.wakeUpScreen();
      } catch (e) {
        Logs().e('[VOIP] foreground setup failed $e');
      }
    }
    addCallingOverlay(call.callId, call);
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    if (overlayEntry != null) {
      overlayEntry!.remove();
      overlayEntry = null;
      if (PlatformInfos.isAndroid) {
        FlutterForegroundTask.setOnLockScreenVisibility(false);
        FlutterForegroundTask.stopService();
        final wasForeground = matrix.store.getString('wasForeground');
        if (wasForeground == 'false') FlutterForegroundTask.minimizeApp();
      }
    }
  }

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {
    // TODO: implement handleGroupCallEnded
  }

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {
    // TODO: implement handleNewGroupCall
    return;
  }

  @override
  // TODO: implement canHandleNewCall
  bool get canHandleNewCall =>
      voip.currentCID == null && voip.currentGroupCID == null;

  @override
  Future<void> handleMissedCall(CallSession session) async {
    // TODO: implement handleMissedCall
    return;
  }

  @override
  // TODO: implement keyProvider
  EncryptionKeyProvider? get keyProvider {
    // TODO: Implement me
    return null;
  }

  @override
  Future<void> registerListeners(CallSession session) async {
    Logs().i('[VOIP] registerListeners: ${session.callId} dir=${session.direction}');
    session.onCallStateChanged.stream.listen((state) {
      Logs().i('[VOIP] call state: $state (${session.callId})');
    });
    return;
  }
}
