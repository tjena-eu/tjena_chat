import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// All event types emitted from the Go bridge.
enum BridgeEventType {
  qr,
  phoneCode,
  linked,
  disconnected,
  state,
  roomCreated,
  roomUpdated,
  roomDeleted,
  message,
  reaction,
  redaction,
  receipt,
  typing,
  presence,
  backfill,
  bridgeStatus,
  msgStatus,
  roomTag,
  roomMuted,
  unread,
  pairError,
  mediaReady,
  signalQr,
  signalLinked,
  signalState,
  signalRoomCreated,
  signalRoomUpdated,
  signalMessage,
  signalReaction,
  signalRedaction,
  signalTyping,
  signalEdit,
  signalMediaReady,
  unknown,
}

class BridgeEvent {
  final BridgeEventType type;
  final Map<String, dynamic> data;

  const BridgeEvent(this.type, this.data);

  static BridgeEvent parse(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    final type = _typeMap[m['type'] as String? ?? ''] ?? BridgeEventType.unknown;
    return BridgeEvent(type, m);
  }

  static const _typeMap = {
    'qr': BridgeEventType.qr,
    'phone_code': BridgeEventType.phoneCode,
    'linked': BridgeEventType.linked,
    'disconnected': BridgeEventType.disconnected,
    'state': BridgeEventType.state,
    'room_created': BridgeEventType.roomCreated,
    'room_updated': BridgeEventType.roomUpdated,
    'room_deleted': BridgeEventType.roomDeleted,
    'message': BridgeEventType.message,
    'reaction': BridgeEventType.reaction,
    'redaction': BridgeEventType.redaction,
    'receipt': BridgeEventType.receipt,
    'typing': BridgeEventType.typing,
    'presence': BridgeEventType.presence,
    'backfill': BridgeEventType.backfill,
    'bridge_status': BridgeEventType.bridgeStatus,
    'msg_status': BridgeEventType.msgStatus,
    'room_tag': BridgeEventType.roomTag,
    'room_muted': BridgeEventType.roomMuted,
    'unread': BridgeEventType.unread,
    'pair_error': BridgeEventType.pairError,
    'media_ready': BridgeEventType.mediaReady,
    'signal_qr': BridgeEventType.signalQr,
    'signal_linked': BridgeEventType.signalLinked,
    'signal_state': BridgeEventType.signalState,
    'signal_room_created': BridgeEventType.signalRoomCreated,
    'signal_room_updated': BridgeEventType.signalRoomUpdated,
    'signal_message': BridgeEventType.signalMessage,
    'signal_reaction': BridgeEventType.signalReaction,
    'signal_redaction': BridgeEventType.signalRedaction,
    'signal_typing': BridgeEventType.signalTyping,
    'signal_edit': BridgeEventType.signalEdit,
    'signal_media_ready': BridgeEventType.signalMediaReady,
  };
}

class BridgeState {
  final bool linked;
  final bool connected;
  final String phone;
  final String pushName;

  const BridgeState({
    required this.linked,
    required this.connected,
    required this.phone,
    required this.pushName,
  });

  factory BridgeState.fromJson(Map<String, dynamic> m) => BridgeState(
        linked: m['linked'] as bool? ?? false,
        connected: m['connected'] as bool? ?? false,
        phone: m['phone'] as String? ?? '',
        pushName: m['push_name'] as String? ?? '',
      );

  static const empty = BridgeState(
    linked: false,
    connected: false,
    phone: '',
    pushName: '',
  );
}

class SignalBridgeState {
  final bool linked;
  final bool connected;
  final String phone;

  const SignalBridgeState({
    required this.linked,
    required this.connected,
    required this.phone,
  });

  factory SignalBridgeState.fromJson(Map<String, dynamic> m) => SignalBridgeState(
        linked: m['linked'] as bool? ?? false,
        connected: m['connected'] as bool? ?? false,
        phone: m['phone'] as String? ?? '',
      );

  static const empty = SignalBridgeState(linked: false, connected: false, phone: '');
}

/// Singleton facade for the Go bridge.
class TjenaBridge {
  TjenaBridge._();
  static final instance = TjenaBridge._();

  static const _method = MethodChannel('tjena.eu/bridge');
  static const _events = EventChannel('tjena.eu/bridge/events');

  Stream<BridgeEvent>? _stream;

  /// Parsed event stream. Subscribe once; survives re-listen.
  Stream<BridgeEvent> get events {
    _stream ??= _events
        .receiveBroadcastStream()
        .map((raw) => BridgeEvent.parse(raw as String))
        .asBroadcastStream();
    return _stream!;
  }

  /// Start the bridge. Idempotent — safe to call on every app launch.
  Future<void> start() async {
    final dir = await getApplicationSupportDirectory();
    final dataDir = '${dir.path}/tjena_bridge';
    await Directory(dataDir).create(recursive: true);
    await _method.invokeMethod<void>('start', {'dataDir': dataDir});
  }

  Future<void> stop() => _method.invokeMethod<void>('stop');

  Future<BridgeState> getState() async {
    final raw = await _method.invokeMethod<String>('getState') ?? '{}';
    return BridgeState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Triggers async QR events on the event stream.
  Future<void> requestQRLink() => _method.invokeMethod<void>('requestQRLink');

  /// Triggers async phone_code event on the event stream.
  Future<void> requestPhoneLink(String phone) =>
      _method.invokeMethod<void>('requestPhoneLink', {'phone': phone});

  Future<void> confirmPhoneLink(String code) =>
      _method.invokeMethod<void>('confirmPhoneLink', {'code': code});

  Future<void> sendText(String portalID, String msgID, String text) =>
      _method.invokeMethod<void>('sendText', {
        'portalID': portalID,
        'msgID': msgID,
        'text': text,
      });

  Future<void> sendReaction(
          String portalID, String targetEventID, String emoji) =>
      _method.invokeMethod<void>('sendReaction', {
        'portalID': portalID,
        'targetEventID': targetEventID,
        'emoji': emoji,
      });

  Future<void> sendRedaction(String portalID, String targetEventID) =>
      _method.invokeMethod<void>('sendRedaction', {
        'portalID': portalID,
        'targetEventID': targetEventID,
      });

  Future<void> markRead(String portalID, String eventID) =>
      _method.invokeMethod<void>('markRead', {
        'portalID': portalID,
        'eventID': eventID,
      });

  Future<void> setTyping(String portalID, {required bool typing}) =>
      _method.invokeMethod<void>('setTyping', {
        'portalID': portalID,
        'typing': typing,
      });

  Future<void> logout() => _method.invokeMethod<void>('logout');

  /// Wipe local device credentials and prepare for fresh linking.
  Future<void> forceReset() => _method.invokeMethod<void>('forceReset');

  Future<void> clearPersistedRooms() =>
      _method.invokeMethod<void>('clearPersistedRooms');

  Future<void> clearSignalRooms() =>
      _method.invokeMethod<void>('clearSignalRooms');

  Future<void> manualSync() => _method.invokeMethod<void>('manualSync');

  Future<void> syncRoom(String jid) =>
      _method.invokeMethod<void>('syncRoom', {'jid': jid});

  /// Re-fetches name and profile picture for the given WA room JID and emits
  /// a room_updated event so the UI refreshes name and avatar.
  Future<void> refreshRoom(String jid) =>
      _method.invokeMethod<void>('refreshRoom', {'jid': jid});

  /// Upload and send media (image/video/audio/document) through WhatsApp.
  Future<void> sendMedia(
    String portalID,
    String msgID,
    String mimeType,
    Uint8List data,
  ) => _method.invokeMethod<void>('sendMedia', {
        'portalID': portalID,
        'msgID': msgID,
        'mimeType': mimeType,
        'data': data,
      });

  /// Send a location through WhatsApp.
  Future<void> sendLocation(String portalID, double lat, double lon) =>
      _method.invokeMethod<void>('sendLocation', {
        'portalID': portalID,
        'lat': lat,
        'lon': lon,
      });

  Future<void> setBackfillConfig({
    required bool seedOnConnect,
    required int days,
  }) => _method.invokeMethod<void>('setBackfillConfig', {
    'seedOnConnect': seedOnConnect,
    'days': days,
  });

  Future<void> startSignal() => _method.invokeMethod<void>('startSignal');
  Future<void> stopSignal() => _method.invokeMethod<void>('stopSignal');

  Future<SignalBridgeState> getSignalState() async {
    final raw =
        await _method.invokeMethod<String>('getSignalStateJSON') ?? '{}';
    return SignalBridgeState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> requestSignalQR() =>
      _method.invokeMethod<void>('requestSignalQR');

  Future<void> signalLogout() => _method.invokeMethod<void>('signalLogout');

  Future<void> signalManualSync() =>
      _method.invokeMethod<void>('signalManualSync');

  /// Returns the last 100 bridge log lines (WARN/ERROR/INFO from whatsmeow).
  Future<String> getLogs() async =>
      await _method.invokeMethod<String>('getLogs') ?? '';
  Future<void> onForeground() => _method.invokeMethod<void>('onForeground');
  Future<void> onBackground() => _method.invokeMethod<void>('onBackground');
}
