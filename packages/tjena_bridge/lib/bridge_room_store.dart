import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'tjena_bridge.dart';

/// A WhatsApp portal room as seen by the Dart/Flutter layer.
class BridgeRoom {
  final String id;
  String name;
  bool isDM;
  String otherUserID;
  String? avatarUri;
  String? lastEventBody;
  int? lastEventTs;
  bool hasUnread;

  BridgeRoom({
    required this.id,
    required this.name,
    required this.isDM,
    required this.otherUserID,
    this.avatarUri,
    this.lastEventBody,
    this.lastEventTs,
    this.hasUnread = false,
  });

  factory BridgeRoom.fromJson(Map<String, dynamic> m) => BridgeRoom(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        isDM: m['is_dm'] as bool? ?? true,
        otherUserID: m['other_user'] as String? ?? '',
        avatarUri: m['avatar_uri'] as String?,
      );
}

/// A single event (message, reaction, redaction…) inside a portal room.
class BridgeRoomEvent {
  final String id;
  final String roomID;
  final String senderID;
  final String senderName;
  final int ts;
  final String body;
  final String msgtype;
  final bool isOwn;
  final bool isBackfill;
  final String? mediaUri;
  final String? reactionEmoji;    // non-null when type == reaction
  final String? targetEventID;   // non-null for reactions/redactions/edits
  final String eventKind;        // "message"|"reaction"|"redaction"|"edit"

  const BridgeRoomEvent({
    required this.id,
    required this.roomID,
    required this.senderID,
    required this.senderName,
    required this.ts,
    required this.body,
    required this.msgtype,
    required this.isOwn,
    required this.isBackfill,
    this.mediaUri,
    this.reactionEmoji,
    this.targetEventID,
    this.eventKind = 'message',
  });

  factory BridgeRoomEvent.fromEventJson(String roomID, Map<String, dynamic> m) =>
      BridgeRoomEvent(
        id: m['id'] as String,
        roomID: roomID,
        senderID: m['sender'] as String? ?? '',
        senderName: m['sender_name'] as String? ?? '',
        ts: m['ts'] as int? ?? 0,
        body: m['body'] as String? ?? '',
        msgtype: m['msgtype'] as String? ?? 'm.text',
        isOwn: m['is_own'] as bool? ?? false,
        isBackfill: m['is_backfill'] as bool? ?? false,
        mediaUri: m['media_uri'] as String?,
        eventKind: 'message',
      );
}

/// In-memory store for bridge rooms and their timelines.
/// Driven by the [TjenaBridge] event stream; notify listeners on change.
class BridgeRoomStore extends ChangeNotifier {
  BridgeRoomStore._();
  static final instance = BridgeRoomStore._();

  final _rooms = <String, BridgeRoom>{};
  final _timelines = <String, List<BridgeRoomEvent>>{};
  final _typing = <String, Set<String>>{};     // roomID → typing user IDs

  StreamSubscription<BridgeEvent>? _sub;

  /// Sorted room list (most-recent-message first).
  List<BridgeRoom> get rooms {
    final list = _rooms.values.toList();
    list.sort((a, b) {
      final ta = a.lastEventTs ?? 0;
      final tb = b.lastEventTs ?? 0;
      return tb.compareTo(ta);
    });
    return list;
  }

  List<BridgeRoomEvent> timelineFor(String roomID) =>
      List.unmodifiable(_timelines[roomID] ?? const []);

  Set<String> typingIn(String roomID) => _typing[roomID] ?? const {};

  void startListening() {
    _sub ??= TjenaBridge.instance.events.listen(_handleEvent);
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
  }

  void _handleEvent(BridgeEvent evt) {
    switch (evt.type) {
      case BridgeEventType.roomCreated:
        final room = BridgeRoom.fromJson(
            evt.data['room'] as Map<String, dynamic>);
        _rooms[room.id] = room;
        _timelines.putIfAbsent(room.id, () => []);

      case BridgeEventType.roomUpdated:
        final roomID = evt.data['room_id'] as String;
        if (_rooms.containsKey(roomID)) {
          if (evt.data['name'] != null) {
            _rooms[roomID]!.name = evt.data['name'] as String;
          }
        }

      case BridgeEventType.roomDeleted:
        final roomID = evt.data['room_id'] as String;
        _rooms.remove(roomID);
        _timelines.remove(roomID);

      case BridgeEventType.message:
        final roomID = evt.data['room_id'] as String;
        final eventData = evt.data['event'] as Map<String, dynamic>;
        final e = BridgeRoomEvent.fromEventJson(roomID, eventData);
        _timelines.putIfAbsent(roomID, () => []).add(e);
        if (_rooms[roomID] != null) {
          _rooms[roomID]!.lastEventBody = e.body;
          _rooms[roomID]!.lastEventTs = e.ts;
          if (!e.isOwn) _rooms[roomID]!.hasUnread = true;
        }

      case BridgeEventType.backfill:
        final roomID = evt.data['room_id'] as String;
        final events = (evt.data['events'] as List<dynamic>)
            .map((m) => BridgeRoomEvent.fromEventJson(
                roomID, m as Map<String, dynamic>))
            .toList();
        final tl = _timelines.putIfAbsent(roomID, () => []);
        // Prepend historical events (they're older).
        tl.insertAll(0, events);

      case BridgeEventType.reaction:
        // Reactions don't need separate storage in Dart layer — render inline.
        final roomID = evt.data['room_id'] as String;
        final e = BridgeRoomEvent(
          id: evt.data['id'] as String? ?? '',
          roomID: roomID,
          senderID: evt.data['sender'] as String? ?? '',
          senderName: '',
          ts: evt.data['ts'] as int? ?? 0,
          body: '',
          msgtype: 'm.reaction',
          isOwn: false,
          isBackfill: false,
          reactionEmoji: evt.data['emoji'] as String?,
          targetEventID: evt.data['target_id'] as String?,
          eventKind: 'reaction',
        );
        _timelines.putIfAbsent(roomID, () => []).add(e);

      case BridgeEventType.redaction:
        final roomID = evt.data['room_id'] as String;
        final targetID = evt.data['target_id'] as String;
        final tl = _timelines[roomID];
        if (tl != null) {
          tl.removeWhere((e) => e.id == targetID);
        }

      case BridgeEventType.typing:
        final roomID = evt.data['room_id'] as String;
        final userID = evt.data['user_id'] as String;
        final typing = evt.data['typing'] as bool? ?? false;
        final set = _typing.putIfAbsent(roomID, () => {});
        if (typing) {
          set.add(userID);
        } else {
          set.remove(userID);
        }

      case BridgeEventType.receipt:
        // Mark read: clear hasUnread when own receipt arrives.
        final roomID = evt.data['room_id'] as String;
        // We don't track per-event receipts in Dart — just clear unread flag
        // when a receipt from the local user comes in.
        _rooms[roomID]?.hasUnread = false;

      case BridgeEventType.unread:
        final roomID = evt.data['room_id'] as String;
        final unread = evt.data['unread'] as bool? ?? false;
        _rooms[roomID]?.hasUnread = unread;

      default:
        break; // state/linked/qr etc. handled by BridgeCubit or link screen
    }
    notifyListeners();
  }
}
