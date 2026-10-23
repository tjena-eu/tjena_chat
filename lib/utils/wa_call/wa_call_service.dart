// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

// WhatsApp calls through the user's own bridge at home.
//
// The bridge phone runs a calls daemon (personal-bridge/wacall) with its own
// linked WhatsApp device. tjena talks to it like this:
//
//   tjena ──wss wap.tjena.eu/_tjena/call/v1/app── gateway ── bridge phone ── WhatsApp
//   tjena ════════ WebRTC audio (DTLS-SRTP, TURN if needed) ═══ bridge phone
//
// The gateway only passes on small JSON messages; audio goes straight to the
// phone. tjena always sends the WebRTC offer with all ICE candidates in it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

import '../../pages/wa_call/wa_call_page.dart';
import '../../widgets/fluffy_chat_app.dart';
import '../personal_bridge.dart';

/// One ringing WhatsApp call on the bridge phone.
class WaRing {
  final String waCallId;

  /// Own WhatsApp number (digits) that is being called.
  final String account;
  final String peer;
  final String? peerPn;
  final String? peerLid;
  final bool video;
  WaRing.fromJson(Map<String, dynamic> j)
    : waCallId = j['wa_call_id'] as String? ?? '',
      account = j['account'] as String? ?? '',
      peer = j['peer'] as String? ?? '',
      peerPn = j['peer_pn'] as String?,
      peerLid = j['peer_lid'] as String?,
      video = j['video'] == true;

  Set<String> get ids =>
      {peer, ?peerPn, ?peerLid}.where((s) => s.isNotEmpty).toSet();
}

enum WaCallPhase { starting, calling, ringing, connecting, active, ended }

/// The call currently in progress.
class WaCall extends ChangeNotifier {
  final String id;
  final bool outgoing;
  final String title;
  final Room? room;
  final String? waCallId;

  /// Own WhatsApp number (digits) the call goes through.
  final String? account;
  WaCallPhase phase = WaCallPhase.starting;
  String? endReason;
  String? error;
  DateTime? activeSince;
  bool muted = false;
  bool speaker = false;
  bool _ended = false;

  RTCPeerConnection? pc;
  MediaStream? local;

  WaCall({
    required this.id,
    required this.outgoing,
    required this.title,
    this.room,
    this.waCallId,
    this.account,
  });

  bool get ended => _ended;

  void changed() => notifyListeners();

  void _set(WaCallPhase p, {String? reason, String? error}) {
    if (_ended) return;
    if (p == WaCallPhase.active && phase != WaCallPhase.active) {
      activeSince = DateTime.now();
    }
    phase = p;
    if (reason != null) endReason = reason;
    if (error != null) this.error = error;
    if (p == WaCallPhase.ended) _ended = true;
    notifyListeners();
  }
}

class WaCallService {
  static WaCallService? _instance;
  static WaCallService? get instance => _instance;

  final Client client;
  WebSocket? _ws;
  Completer<void>? _connecting;
  StreamSubscription? _timelineSub;
  Timer? _idleClose;

  /// Whether the bridge phone's calls daemon is connected to the gateway.
  final phoneOnline = ValueNotifier<bool?>(null);
  final ringing = ValueNotifier<List<WaRing>>([]);
  final current = ValueNotifier<WaCall?>(null);

  final _sdpWaiters = <String, Completer<String>>{};
  final _shownRings = <String>{};

  WaCallService._(this.client);

  /// Starts listening for WhatsApp call notices. Safe to call repeatedly.
  static WaCallService start(Client client) {
    final existing = _instance;
    if (existing != null && existing.client == client) return existing;
    existing?._dispose();
    final s = WaCallService._(client);
    s._timelineSub = client.onTimelineEvent.stream.listen(s._onEvent);
    return _instance = s;
  }

  void _dispose() {
    _timelineSub?.cancel();
    _ws?.close();
  }

  // ------------------------------------------------------------- rooms

  static String? channelId(Room room) {
    for (final type in const ['m.bridge', 'uk.half-shot.bridge']) {
      final states = room.states[type];
      if (states == null || states.isEmpty) continue;
      final content = states.values.first.content;
      final id = (content['channel'] as Map?)?['id'];
      if (id is String) return id;
    }
    return null;
  }

  /// A 1:1 WhatsApp chat of the user's own bridge: what to call.
  static String? callTarget(Room room) {
    final info = RoomBridgeInfo.of(room);
    if (info == null || !info.isOwnBridge(room.client)) return null;
    final id = channelId(room);
    if (id == null) return null;
    if (id.endsWith('@s.whatsapp.net') || id.endsWith('@lid')) return id;
    return null;
  }

  /// The own WhatsApp account (phone digits, the bridge login ID) a portal
  /// belongs to: bridgev2 puts it in m.bridge as channel["fi.mau.receiver"].
  static String? account(Room room) {
    for (final type in const ['m.bridge', 'uk.half-shot.bridge']) {
      final states = room.states[type];
      if (states == null || states.isEmpty) continue;
      final r =
          (states.values.first.content['channel'] as Map?)?['fi.mau.receiver'];
      if (r is String && r.isNotEmpty) return r;
    }
    return null;
  }

  /// The chat of the caller, in the account that is being called.
  Room? _roomForPeer(WaRing r) {
    final ids = r.ids;
    final matches = client.rooms.where((room) {
      final c = callTarget(room);
      return c != null && ids.contains(c);
    }).toList();
    return matches.firstWhereOrNull((room) => account(room) == r.account) ??
        (matches.length == 1 ? matches.single : null);
  }

  /// "…1234": short label of an own WhatsApp account, shown when the user
  /// has more than one.
  String? accountLabel(String? acct) {
    if (acct == null || acct.isEmpty) return null;
    final all = client.rooms.map(account).whereType<String>().toSet();
    if (all.length < 2) return null;
    return '…${acct.length > 4 ? acct.substring(acct.length - 4) : acct}';
  }

  // ------------------------------------------------------------- signalling

  String get _gateway {
    final g = WhatsAppBridgeConfig.of(client).gateway;
    return g.endsWith('/') ? g.substring(0, g.length - 1) : g;
  }

  Future<void> _ensureConnected() async {
    if (_ws != null && _ws!.readyState == WebSocket.open) return;
    if (_connecting != null) return _connecting!.future;
    final done = _connecting = Completer<void>();
    try {
      final token = await PersonalBridgeApi.openIdToken(client);
      final url =
          '${_gateway.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://')}/_tjena/call/v1/app';
      final ws = await WebSocket.connect(
        url,
        headers: {'Authorization': 'Bearer openid:$token'},
      ).timeout(const Duration(seconds: 15));
      ws.pingInterval = const Duration(seconds: 25);
      _ws = ws;
      final firstNotice = Completer<void>();
      ws.listen(
        (data) {
          if (data is! String) return;
          try {
            final m = jsonDecode(data) as Map<String, dynamic>;
            if (m['type'] == 'phone' && !firstNotice.isCompleted) {
              firstNotice.complete();
            }
            _onMessage(m);
          } catch (e, s) {
            Logs().w('[WaCall] bad message', e, s);
          }
        },
        onDone: () {
          if (_ws == ws) _ws = null;
          phoneOnline.value = null;
        },
        onError: (_) {},
        cancelOnError: true,
      );
      await firstNotice.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      done.complete();
    } catch (e) {
      done.completeError(e);
      rethrow;
    } finally {
      _connecting = null;
    }
  }

  void _send(Map<String, dynamic> m) {
    final ws = _ws;
    if (ws == null) throw Exception('Not connected to your bridge');
    ws.add(jsonEncode(m));
  }

  /// Closes the signalling connection a while after the last call.
  void _scheduleIdleClose() {
    _idleClose?.cancel();
    _idleClose = Timer(const Duration(minutes: 2), () {
      if (current.value == null && ringing.value.isEmpty) {
        _ws?.close();
        _ws = null;
      }
    });
  }

  void _onMessage(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'phone':
        phoneOnline.value = m['online'] == true;
        if (m['online'] == true) {
          try {
            _send({'type': 'status'});
          } catch (_) {}
        }
        break;
      case 'status':
        final calls = (m['calls'] as List? ?? [])
            .map((c) => WaRing.fromJson((c as Map).cast<String, dynamic>()))
            .toList();
        ringing.value = calls;
        calls.forEach(_showIncoming);
        break;
      case 'incoming':
        final r = WaRing.fromJson((m['call'] as Map).cast<String, dynamic>());
        ringing.value = [
          ...ringing.value.where((x) => x.waCallId != r.waCallId),
          r,
        ];
        _showIncoming(r);
        break;
      case 'incoming_gone':
        final id = m['wa_call_id'];
        ringing.value = ringing.value.where((x) => x.waCallId != id).toList();
        final c = current.value;
        if (c != null &&
            !c.outgoing &&
            c.waCallId == id &&
            c.phase == WaCallPhase.starting) {
          _end(c, reason: m['reason'] as String? ?? 'gone');
        }
        break;
      case 'sdp':
        _sdpWaiters.remove(m['id'])?.complete(m['sdp'] as String);
        break;
      case 'state':
        final c = current.value;
        if (c == null || c.id != m['id']) return;
        final st = m['state'] as String?;
        if (st == 'ended') {
          _sdpWaiters
              .remove(c.id)
              ?.completeError(Exception(m['error'] ?? 'Call ended'));
          _end(
            c,
            reason: m['reason'] as String?,
            error: m['error'] as String?,
            notifyPhone: false,
          );
          return;
        }
        final phase = switch (st) {
          'calling' => WaCallPhase.calling,
          'ringing' => WaCallPhase.ringing,
          'accepted' || 'connecting' => WaCallPhase.connecting,
          'active' => WaCallPhase.active,
          _ => null,
        };
        if (phase != null) c._set(phase);
        break;
    }
  }

  // ------------------------------------------------------------- incoming

  void _onEvent(Event e) {
    if (e.senderId == client.userID) return;
    final action = e.content['com.beeper.action_message'];
    if (action is! Map || action['type'] != 'call') return;
    final age = DateTime.now().difference(e.originServerTs);
    if (age > const Duration(minutes: 1)) return;
    final room = e.room;
    if (callTarget(room) == null) return;
    // The bridge says a WhatsApp call is ringing: ask our calls device.
    unawaited(checkRinging());
  }

  /// Opening a chat from the "Incoming call" notification: pick it up here.
  void checkRoom(Room room) {
    final last = room.lastEvent;
    if (last == null || callTarget(room) == null) return;
    _onEvent(last);
  }

  Future<void> checkRinging() async {
    try {
      await _ensureConnected();
      _send({'type': 'status'});
      _scheduleIdleClose();
    } catch (e) {
      Logs().w('[WaCall] cannot reach the bridge for incoming calls: $e');
    }
  }

  void _showIncoming(WaRing r) {
    if (current.value != null || _shownRings.contains(r.waCallId)) return;
    _shownRings.add(r.waCallId);
    final room = _roomForPeer(r);
    final nav = FluffyChatApp.router.routerDelegate.navigatorKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => WaIncomingCallPage(
          service: this,
          ring: r,
          title: room?.getLocalizedDisplayname() ?? _pretty(r.peerPn ?? r.peer),
          room: room,
        ),
      ),
    );
  }

  static String _pretty(String jid) {
    final user = jid.split('@').first;
    return jid.endsWith('@s.whatsapp.net') ? '+$user' : 'WhatsApp contact';
  }

  // ------------------------------------------------------------- calls

  static String _newId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
  }

  /// Calls the WhatsApp contact of [room]. Returns the call (also in [current]).
  Future<WaCall> dial(Room room) async {
    final target = callTarget(room);
    if (target == null) {
      throw Exception('This is not a WhatsApp chat of your own bridge');
    }
    final call = WaCall(
      id: _newId(),
      outgoing: true,
      title: room.getLocalizedDisplayname(),
      room: room,
      account: account(room),
    );
    await _startCall(call, {
      'type': 'call',
      'target': target,
      // Call out from the WhatsApp account this chat belongs to.
      if (call.account != null) 'account': call.account,
    });
    return call;
  }

  /// Answers a ringing WhatsApp call.
  Future<WaCall> answer(WaRing r, {required String title, Room? room}) async {
    final call = WaCall(
      id: _newId(),
      outgoing: false,
      title: title,
      room: room,
      waCallId: r.waCallId,
      account: r.account,
    );
    ringing.value = ringing.value
        .where((x) => x.waCallId != r.waCallId)
        .toList();
    await _startCall(call, {'type': 'answer', 'wa_call_id': r.waCallId});
    return call;
  }

  Future<void> reject(WaRing r) async {
    ringing.value = ringing.value
        .where((x) => x.waCallId != r.waCallId)
        .toList();
    try {
      await _ensureConnected();
      _send({'type': 'reject', 'wa_call_id': r.waCallId});
    } catch (_) {}
    _scheduleIdleClose();
  }

  Future<void> _startCall(WaCall call, Map<String, dynamic> request) async {
    if (current.value != null && !current.value!.ended) {
      throw Exception('Another call is in progress');
    }
    current.value = call;
    try {
      await _ensureConnected();
      if (phoneOnline.value != true) {
        throw Exception(
          'Your bridge phone is not reachable. Check that calls are turned on in the tjena Bridge app.',
        );
      }
      final turn = await _iceServers();
      final pc = call.pc = await createPeerConnection({
        'iceServers': turn,
        'sdpSemantics': 'unified-plan',
      });
      pc.onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _end(call, reason: 'connection_failed');
        }
      };
      final local = call.local = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      for (final t in local.getAudioTracks()) {
        await pc.addTrack(t, local);
      }
      final offer = await pc.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      final gathered = Completer<void>();
      pc.onIceGatheringState = (s) {
        if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !gathered.isCompleted) {
          gathered.complete();
        }
      };
      await pc.setLocalDescription(offer);
      await gathered.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () {},
      );
      final desc = await pc.getLocalDescription();
      if (call.ended) return;

      final answer = Completer<String>();
      _sdpWaiters[call.id] = answer;
      _send({...request, 'id': call.id, 'sdp': desc!.sdp, 'ice_servers': turn});
      final sdp = await answer.future.timeout(const Duration(seconds: 40));
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      if (call.phase == WaCallPhase.starting) {
        call._set(call.outgoing ? WaCallPhase.calling : WaCallPhase.connecting);
      }
      await Helper.setSpeakerphoneOn(false);
    } catch (e) {
      Logs().w('[WaCall] call failed', e);
      _end(
        call,
        reason: 'error',
        error: e.toString().replaceFirst('Exception: ', ''),
      );
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _iceServers() async {
    try {
      final t = await client.getTurnServer();
      return [
        {'urls': t.uris, 'username': t.username, 'credential': t.password},
      ];
    } catch (e) {
      Logs().w('[WaCall] no TURN server: $e');
      return [
        {
          'urls': ['stun:stun.l.google.com:19302'],
        },
      ];
    }
  }

  void hangup(WaCall call) => _end(call, reason: 'hangup');

  void setMuted(WaCall call, bool muted) {
    call.muted = muted;
    for (final t in call.local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    call.changed();
  }

  Future<void> setSpeaker(WaCall call, bool on) async {
    call.speaker = on;
    await Helper.setSpeakerphoneOn(on);
    call.changed();
  }

  void _end(
    WaCall call, {
    String? reason,
    String? error,
    bool notifyPhone = true,
  }) {
    if (call.ended) return;
    if (notifyPhone) {
      try {
        _send({'type': 'hangup', 'id': call.id});
      } catch (_) {}
    }
    _sdpWaiters.remove(call.id);
    call._set(WaCallPhase.ended, reason: reason, error: error);
    for (final t in call.local?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    call.local?.dispose();
    call.pc?.close();
    if (current.value == call) current.value = null;
    _scheduleIdleClose();
  }
}
