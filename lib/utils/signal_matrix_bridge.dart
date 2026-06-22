// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import '../config/setting_keys.dart';
import 'matrix_sdk_extensions/matrix_file_extension.dart';
import 'platform_infos.dart';

/// Converts Signal bridge events into virtual Matrix rooms via handleSync.
class SignalMatrixBridge {
  SignalMatrixBridge._();
  static final instance = SignalMatrixBridge._();

  Client? _client;

  final _sigToMatrix = <String, String>{};
  final _matrixToSig = <String, String>{};
  final _pendingMediaEvents = <String, Map<String, dynamic>>{};

  StreamSubscription<BridgeEvent>? _sub;

  String? _spaceId;

  static const _bridgeStateType = 'org.tjena.signal.local';
  static const _spaceRoomId = '!sig_space_local:local';

  static String _toMatrixId(String sigId) =>
      '!sig_${sigId.replaceAll('-', '_').replaceAll('@', '_')}:local';

  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

  void init(Client client) {
    _client = client;
    for (final room in client.rooms) {
      if (room.id == _spaceRoomId) {
        _spaceId = _spaceRoomId;
        continue;
      }
      final state = room.getState(_bridgeStateType);
      if (state == null) continue;
      final sigId = state.content['sig_room_id'] as String?;
      if (sigId != null) {
        _sigToMatrix[sigId] = room.id;
        _matrixToSig[room.id] = sigId;
      }
    }
    _sub?.cancel();
    _sub = TjenaBridge.instance.events.listen(
      _onBridgeEvent,
      onError: (e, s) => Logs().w('[SigBridge] stream error', e, s),
      cancelOnError: false,
    );
  }

  bool isSigRoom(String matrixRoomId) => _matrixToSig.containsKey(matrixRoomId);
  String? sigRoomId(String matrixRoomId) => _matrixToSig[matrixRoomId];
  String? matrixRoomId(String sigId) => _sigToMatrix[sigId];
  bool get isLinked => _sigToMatrix.isNotEmpty;
  String? matrixRoomIdForPhone(String phone) {
    final normalized = phone.replaceAll('+', '').replaceAll(' ', '');
    final val = _sigToMatrix.entries
        .firstWhere(
          (e) => e.key.contains(normalized),
          orElse: () => const MapEntry('', ''),
        )
        .value;
    return val.isEmpty ? null : val;
  }

  Future<void> clearAllRooms(Client client) async {
    final toRemove = List<String>.from(_matrixToSig.keys);
    for (final matrixId in toRemove) {
      final sig = _matrixToSig[matrixId];
      if (sig != null) _sigToMatrix.remove(sig);
      _matrixToSig.remove(matrixId);
      await _leaveRoom(client, matrixId);
    }
    if (_spaceId != null) {
      await _leaveRoom(client, _spaceId!);
      _spaceId = null;
    }
    TjenaBridge.instance.clearSignalRooms();
  }

  Future<void> _leaveRoom(Client client, String matrixId) async {
    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(leave: {
        matrixId: LeftRoomUpdate(timeline: TimelineUpdate(events: [])),
      }),
    ));
  }

  // ── event dispatch ──────────────────────────────────────────────────────

  void _onBridgeEvent(BridgeEvent evt) {
    try {
      _onBridgeEventInner(evt);
    } catch (e, s) {
      Logs().w('[SigBridge] event error', e, s);
    }
  }

  void _onBridgeEventInner(BridgeEvent evt) {
    final d = evt.data;
    switch (evt.type) {
      case BridgeEventType.signalState:
        final linked = d['linked'] as bool? ?? false;
        final connected = d['connected'] as bool? ?? false;
        if (linked && connected) _ensureSpace();
        break;
      case BridgeEventType.signalLinked:
        _ensureSpace();
        break;
      case BridgeEventType.signalRoomCreated:
        final room = d['room'] as Map<String, dynamic>?;
        if (room == null) break;
        final sigId = room['id'] as String? ?? '';
        final name = room['name'] as String? ?? sigId;
        final isDM = room['is_dm'] as bool? ?? true;
        if (sigId.isEmpty) break;
        _ensureRoom(sigId, name, isDM: isDM);
        break;
      case BridgeEventType.signalRoomUpdated:
        _handleRoomUpdated(d);
        break;
      case BridgeEventType.signalMessage:
        final sigId = d['room_id'] as String? ?? '';
        final matrixId = _sigToMatrix[sigId];
        if (matrixId == null) break;
        _pushMessage(d, sigId, matrixId);
        break;
      case BridgeEventType.signalMediaReady:
        _pushMediaReady(
          d['room_id'] as String? ?? '',
          d['event_id'] as String? ?? '',
          d['file_path'] as String? ?? '',
          d['mime_type'] as String? ?? 'application/octet-stream',
          (d['size'] as num?)?.toInt() ?? 0,
        );
        break;
      case BridgeEventType.signalReaction:
        _pushReaction(d);
        break;
      case BridgeEventType.signalRedaction:
        _pushRedaction(d);
        break;
      case BridgeEventType.signalTyping:
        _pushTyping(d);
        break;
      default:
        break;
    }
  }

  void _handleRoomUpdated(Map<String, dynamic> d) {
    final sigId = d['room_id'] as String? ?? '';
    if (sigId.isEmpty) return;
    final matrixId = _sigToMatrix[sigId];
    if (matrixId == null) return;
    final client = _client;
    if (client?.userID == null) return;

    final name = d['name'] as String?;
    final avatarBytes = d['avatar_bytes'];

    if (name != null) {
      final ts = DateTime.now();
      // ignore: unawaited_futures
      client!.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            state: [
              MatrixEvent(
                type: EventTypes.RoomName,
                content: {'name': name},
                senderId: client.userID!,
                eventId: '\$signame_${_safe(sigId)}_${ts.millisecondsSinceEpoch}',
                originServerTs: ts,
                stateKey: '',
              ),
            ],
          ),
        }),
      ));
    }

    if (avatarBytes != null) {
      final bytes = _toBytes(avatarBytes);
      if (bytes != null) _storeAvatar(matrixId, sigId, bytes, client!);
    }
  }

  // ── space ────────────────────────────────────────────────────────────────

  void _ensureSpace() {
    final client = _client;
    if (client?.userID == null) return;
    if (_spaceId != null && client!.getRoomById(_spaceId!) != null) return;
    _spaceId = _spaceRoomId;
    final myId = client!.userID!;
    final now = DateTime.now();
    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        _spaceRoomId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomCreate,
              content: {'creator': myId, 'room_version': '10', 'type': 'm.space'},
              senderId: myId,
              eventId: '\$sig_space_create',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': 'Signal'},
              senderId: myId,
              eventId: '\$sig_space_name',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomMember,
              content: {'membership': 'join'},
              senderId: myId,
              eventId: '\$sig_space_member',
              originServerTs: now,
              stateKey: myId,
            ),
          ],
          timeline: TimelineUpdate(events: [], limited: false),
        ),
      }),
    ));
  }

  void _addRoomToSpace(String matrixId) {
    final spaceId = _spaceId;
    final client = _client;
    if (spaceId == null || client?.userID == null) return;
    final ts = DateTime.now();
    // ignore: unawaited_futures
    client!.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        spaceId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: 'm.space.child',
              content: {'via': <String>['local']},
              senderId: client.userID!,
              eventId: '\$sig_child_${_safe(matrixId)}_${ts.millisecondsSinceEpoch}',
              originServerTs: ts,
              stateKey: matrixId,
            ),
          ],
        ),
      }),
    ));
  }

  // ── rooms ────────────────────────────────────────────────────────────────

  void _ensureRoom(String sigId, String name, {required bool isDM}) {
    if (_sigToMatrix.containsKey(sigId)) {
      _pushNameUpdate(sigId, name);
      return;
    }
    final client = _client;
    if (client?.userID == null) return;
    final matrixId = _toMatrixId(sigId);
    _sigToMatrix[sigId] = matrixId;
    _matrixToSig[matrixId] = sigId;

    final myId = client!.userID!;
    final sid = _safe(sigId);
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch;

    final state = <MatrixEvent>[
      MatrixEvent(
        type: EventTypes.RoomCreate,
        content: {'creator': myId, 'room_version': '10'},
        senderId: myId,
        eventId: '\$sigcreate_$sid',
        originServerTs: now,
        stateKey: '',
      ),
      MatrixEvent(
        type: EventTypes.RoomName,
        content: {'name': name.isNotEmpty ? name : sigId},
        senderId: myId,
        eventId: '\$signame_${sid}_$ts',
        originServerTs: now,
        stateKey: '',
      ),
      MatrixEvent(
        type: EventTypes.RoomMember,
        content: {'membership': 'join'},
        senderId: myId,
        eventId: '\$sigmember_$sid',
        originServerTs: now,
        stateKey: myId,
      ),
      MatrixEvent(
        type: _bridgeStateType,
        content: {'sig_room_id': sigId, 'is_dm': isDM},
        senderId: myId,
        eventId: '\$sigbridge_$sid',
        originServerTs: now,
        stateKey: '',
      ),
    ];

    if (isDM) {
      state.add(MatrixEvent(
        type: EventTypes.RoomMember,
        content: {'membership': 'join', 'displayname': name},
        senderId: '@sig_$sigId:local',
        eventId: '\$sigother_$sid',
        originServerTs: now,
        stateKey: '@sig_$sigId:local',
      ));
    }

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          state: state,
          timeline: TimelineUpdate(events: [], limited: false),
        ),
      }),
    ));
    _ensureSpace();
    _addRoomToSpace(matrixId);
  }

  void _pushNameUpdate(String sigId, String name) {
    final matrixId = _sigToMatrix[sigId];
    final client = _client;
    if (matrixId == null || client?.userID == null) return;
    final ts = DateTime.now();
    // ignore: unawaited_futures
    client!.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': name},
              senderId: client.userID!,
              eventId: '\$signame_${_safe(sigId)}_${ts.millisecondsSinceEpoch}',
              originServerTs: ts,
              stateKey: '',
            ),
          ],
        ),
      }),
    ));
  }

  void _storeAvatar(String matrixId, String sigId, Uint8List bytes, Client client) {
    final mxcUri = Uri.parse('mxc://sig-local/${matrixId.hashCode.abs()}');
    client.database
        .storeFile(mxcUri, bytes, DateTime.now().millisecondsSinceEpoch ~/ 1000)
        .then((_) {
      final ts = DateTime.now();
      // ignore: unawaited_futures
      client.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            state: [
              MatrixEvent(
                type: EventTypes.RoomAvatar,
                content: {'url': mxcUri.toString()},
                senderId: client.userID ?? '',
                eventId: '\$sigavatar_${_safe(sigId)}_${ts.millisecondsSinceEpoch}',
                originServerTs: ts,
                stateKey: '',
              ),
            ],
          ),
        }),
      ));
    }).catchError((_) {});
  }

  // ── messages ─────────────────────────────────────────────────────────────

  void _pushMessage(
    Map<String, dynamic> d,
    String sigId,
    String matrixId, {
    bool isBackfill = false,
  }) {
    final client = _client;
    if (client == null) return;

    final eventId = d['event_id'] as String? ?? '\$sig_${DateTime.now().millisecondsSinceEpoch}';
    final sender = d['sender'] as String? ?? sigId;
    final matrixSender = '@sig_$sender:local';
    final tsMs = (d['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final body = d['body'] as String? ?? '';
    final msgtype = d['msgtype'] as String? ?? 'm.text';

    final content = <String, dynamic>{'msgtype': msgtype, 'body': body};

    final needsMedia = msgtype != 'm.text';
    if (needsMedia && !isBackfill) {
      _pendingMediaEvents[eventId] = {
        'sigId': sigId,
        'matrixId': matrixId,
        'sender': matrixSender,
        'ts': tsMs,
        'body': body,
        'msgtype': msgtype,
      };
    }

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                eventId: eventId,
                senderId: matrixSender,
                type: EventTypes.Message,
                originServerTs: DateTime.fromMillisecondsSinceEpoch(tsMs),
                content: content,
                roomId: matrixId,
              ),
            ],
          ),
        ),
      }),
    ));
  }

  void _pushMediaReady(
    String sigId,
    String eventId,
    String filePath,
    String mimetype,
    int size,
  ) {
    final client = _client;
    if (client == null) return;
    final matrixId = _sigToMatrix[sigId];
    if (matrixId == null) return;
    final pending = _pendingMediaEvents.remove(eventId);
    if (pending == null) return;

    final file = File(filePath);
    if (!file.existsSync()) return;
    final bytes = file.readAsBytesSync();
    final mxcUri = Uri.parse('mxc://sig-media/${eventId.replaceAll(r'$', '')}');

    client.database
        .storeFile(mxcUri, bytes, DateTime.now().millisecondsSinceEpoch ~/ 1000)
        .then((_) {
      final body = pending['body'] as String? ?? '';
      final msgtype = pending['msgtype'] as String? ?? 'm.file';
      final sender = pending['sender'] as String? ?? '@sig_unknown:local';
      final tsMs = (pending['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;

      _autoSaveMedia(bytes, body, msgtype);

      final content = <String, dynamic>{
        'msgtype': msgtype,
        'body': body,
        'url': mxcUri.toString(),
        'info': {'mimetype': mimetype, 'size': size},
      };

      // ignore: unawaited_futures
      client.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: [
                MatrixEvent(
                  eventId: eventId,
                  senderId: sender,
                  type: EventTypes.Message,
                  originServerTs: DateTime.fromMillisecondsSinceEpoch(tsMs),
                  content: content,
                  roomId: matrixId,
                ),
              ],
            ),
          ),
        }),
      ));
    }).catchError((_) {});
  }

  void _pushReaction(Map<String, dynamic> d) {
    final client = _client;
    if (client == null) return;
    final sigId = d['room_id'] as String? ?? '';
    final matrixId = _sigToMatrix[sigId];
    if (matrixId == null) return;
    final sender = d['sender'] as String? ?? '';
    final tsMs = (d['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final emoji = d['emoji'] as String? ?? '';
    final targetTs = d['target_ts'] as int? ?? 0;
    final targetEventId = '\$sig_$targetTs';

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                eventId: '\$sig_react_${tsMs}_$sender',
                senderId: '@sig_$sender:local',
                type: EventTypes.Reaction,
                originServerTs: DateTime.fromMillisecondsSinceEpoch(tsMs),
                content: {
                  'm.relates_to': {
                    'rel_type': RelationshipTypes.reaction,
                    'event_id': targetEventId,
                    'key': emoji,
                  },
                },
                roomId: matrixId,
              ),
            ],
          ),
        ),
      }),
    ));
  }

  void _pushRedaction(Map<String, dynamic> d) {
    final client = _client;
    if (client == null) return;
    final sigId = d['room_id'] as String? ?? '';
    final matrixId = _sigToMatrix[sigId];
    if (matrixId == null) return;
    final sender = d['sender'] as String? ?? '';
    final tsMs = (d['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final targetTs = d['target_ts'] as int? ?? 0;
    final targetEventId = '\$sig_$targetTs';

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                eventId: '\$sig_del_${tsMs}_$sender',
                senderId: '@sig_$sender:local',
                type: EventTypes.Redaction,
                originServerTs: DateTime.fromMillisecondsSinceEpoch(tsMs),
                content: {'redacts': targetEventId},
                roomId: matrixId,
              ),
            ],
          ),
        ),
      }),
    ));
  }

  void _pushTyping(Map<String, dynamic> d) {
    final client = _client;
    if (client == null) return;
    final sigId = d['room_id'] as String? ?? '';
    final matrixId = _sigToMatrix[sigId];
    if (matrixId == null) return;
    final sender = d['sender'] as String? ?? '';
    final typing = d['typing'] as bool? ?? false;
    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          ephemeral: [
            MatrixEvent(
              type: 'm.typing',
              content: {
                'user_ids': typing ? <String>['@sig_$sender:local'] : <String>[],
              },
              senderId: '',
              eventId: '',
              originServerTs: DateTime.now(),
            ),
          ],
        ),
      }),
    ));
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  Uint8List? _toBytes(dynamic v) {
    if (v is List) return Uint8List.fromList(v.cast<int>());
    return null;
  }

  static void _autoSaveMedia(Uint8List bytes, String body, String msgtype) {
    if (kIsWeb || !PlatformInfos.isMobile) return;
    if (!AppSettings.autoSaveMedia.value) return;
    final isImage = msgtype == 'm.image';
    final isVideo = msgtype == 'm.video';
    if (!isImage && !isVideo) return;
    final file = isImage
        ? MatrixImageFile(bytes: bytes, name: body)
        : MatrixVideoFile(bytes: bytes, name: body);
    final fileName = MatrixFileExtension.galleryName(
      'signal',
      originalName: body,
      video: isVideo,
    );
    file.saveToGallery(fileName: fileName).catchError((_) => false);
  }
}
