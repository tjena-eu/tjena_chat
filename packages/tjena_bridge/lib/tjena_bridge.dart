import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  /// Returns the last 100 bridge log lines (WARN/ERROR/INFO from whatsmeow).
  Future<String> getLogs() async =>
      await _method.invokeMethod<String>('getLogs') ?? '';
  Future<void> onForeground() => _method.invokeMethod<void>('onForeground');
  Future<void> onBackground() => _method.invokeMethod<void>('onBackground');
}
