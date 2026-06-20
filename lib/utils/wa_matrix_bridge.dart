// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import 'matrix_sdk_extensions/matrix_file_extension.dart';

import '../config/setting_keys.dart';
import 'platform_infos.dart';

/// Converts WA bridge events into virtual Matrix rooms injected via handleSync.
/// Once injected, FluffyChat treats WA rooms identically to real Matrix rooms.
class WaMatrixBridge {
  WaMatrixBridge._();
  static final instance = WaMatrixBridge._();

  Client? _client;

  // Bidirectional WA JID ↔ Matrix room ID mapping
  final _waToMatrix = <String, String>{};
  final _matrixToWa = <String, String>{};

  // eventId → original event data, kept until media_ready allows re-injection
  final _pendingMediaEvents = <String, Map<String, dynamic>>{};

  // "$matrixRoomId/$senderId" → last display name we injected, avoids re-injecting unchanged names
  final _senderNames = <String, String>{};

  StreamSubscription<BridgeEvent>? _sub;

  String? _spaceId;
  String? _connectedPhone;

  static const _bridgeStateType = 'org.tjena.bridge.local';
  static const _spaceRoomId = '!wa_space_local:local';

  static String _toMatrixId(String waRoomId) =>
      '!wa_${waRoomId.replaceAll('@', '_')}:local';

  // ── Init ─────────────────────────────────────────────────────────────────────

  void init(Client client) {
    _client = client;
    // Rebuild mapping from rooms already in local DB.
    for (final room in client.rooms) {
      if (room.id == _spaceRoomId) {
        _spaceId = _spaceRoomId;
        continue;
      }
      final state = room.getState(_bridgeStateType);
      if (state == null) continue;
      final waId = state.content['wa_room_id'] as String?;
      if (waId != null) {
        _waToMatrix[waId] = room.id;
        _matrixToWa[room.id] = waId;
      }
    }
    _sub?.cancel();
    _sub = TjenaBridge.instance.events.listen(
      _onBridgeEvent,
      onError: (e, s) => Logs().w('[WaBridge] stream error', e, s),
      cancelOnError: false,
    );
  }

  bool isWaRoom(String matrixRoomId) => _matrixToWa.containsKey(matrixRoomId);
  String? waRoomId(String matrixRoomId) => _matrixToWa[matrixRoomId];
  String? matrixRoomId(String waRoomId) => _waToMatrix[waRoomId];
  bool get isLinked => _connectedPhone != null;
  String? get connectedPhone => _connectedPhone;
  String? matrixRoomIdForPhone(String phone) {
    final jid = '${phone.replaceAll('+', '').replaceAll(' ', '')}@s.whatsapp.net';
    return _waToMatrix[jid];
  }

  // ── Public actions ────────────────────────────────────────────────────────────

  Future<void> sendText(String matrixRoomId, String text) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final eventId = '\$wa_out_${DateTime.now().millisecondsSinceEpoch}';
    // Inject locally first so the message appears immediately in the chat.
    final client = _client;
    if (client?.userID != null) {
      client!.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixRoomId: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: [
                MatrixEvent(
                  type: EventTypes.Message,
                  content: {'msgtype': 'm.text', 'body': text},
                  senderId: client.userID!,
                  eventId: eventId,
                  originServerTs: DateTime.now(),
                  roomId: matrixRoomId,
                ),
              ],
              limited: false,
            ),
          ),
        }),
      ));
    }
    await TjenaBridge.instance.sendText(waId, eventId, text);
  }

  /// Refresh name and avatar for a room from the Go bridge (live network fetch).
  Future<void> refreshRoom(String matrixRoomId) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    try {
      await TjenaBridge.instance.refreshRoom(waId);
    } catch (e) {
      Logs().w('[WaBridge] refreshRoom failed: $e');
    }
  }

  /// Call when the user opens a WA room to clear unread count and send WA receipt.
  Future<void> markRoomRead(Client client, String matrixRoomId) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final room = client.getRoomById(matrixRoomId);
    final lastEventId = room?.lastEvent?.eventId;
    // Reset unread count locally via a read receipt ephemeral event.
    if (lastEventId != null) {
      // ignore: unawaited_futures
      client.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixRoomId: JoinedRoomUpdate(
            ephemeral: [
              BasicEvent(
                type: 'm.receipt',
                content: {
                  lastEventId: {
                    'm.read': {
                      client.userID!: {
                        'ts': DateTime.now().millisecondsSinceEpoch,
                      },
                    },
                  },
                },
              ),
            ],
            unreadNotifications: UnreadNotificationCounts(
              notificationCount: 0,
              highlightCount: 0,
            ),
          ),
        }),
      ));
    }
    // Send WA read receipt (fire and forget — failures are non-fatal).
    try {
      await TjenaBridge.instance.markRead(waId, lastEventId ?? '');
    } catch (_) {}
  }

  /// Send a reaction to a WA message.
  /// Pass [emoji] as empty string to remove an existing reaction.
  Future<void> sendReaction(
    String matrixRoomId,
    String targetMatrixEventId,
    String emoji,
  ) async {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    final targetWaId = targetMatrixEventId.startsWith(r'$wa_')
        ? targetMatrixEventId.substring(4)
        : targetMatrixEventId;
    try {
      await TjenaBridge.instance.sendReaction(waId, targetWaId, emoji);
    } catch (_) {}
  }

  /// Delete a WA message and inject a local Matrix redaction.
  Future<void> redactMessage(String matrixRoomId, String eventId) async {
    final waId = _matrixToWa[matrixRoomId];
    final client = _client;
    if (waId == null || client?.userID == null) return;
    final targetWaId =
        eventId.startsWith(r'$wa_') ? eventId.substring(4) : eventId;
    try {
      await TjenaBridge.instance.sendRedaction(waId, targetWaId);
    } catch (_) {}
    // Inject local redaction for immediate UI update.
    final ts = DateTime.now();
    // ignore: unawaited_futures
    client!.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixRoomId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: EventTypes.Redaction,
                content: {'redacts': eventId},
                senderId: client.userID!,
                eventId:
                    '\$wa_redact_${_safe(eventId)}_${ts.millisecondsSinceEpoch}',
                originServerTs: ts,
                roomId: matrixRoomId,
              ),
            ],
            limited: false,
          ),
        ),
      }),
    ));
  }

  /// Fire a typing notification to WA (best-effort, never throws).
  void notifyTyping(String matrixRoomId, bool typing) {
    final waId = _matrixToWa[matrixRoomId];
    if (waId == null) return;
    TjenaBridge.instance
        .setTyping(waId, typing: typing)
        .catchError((_) {});
  }

  /// Remove a WA virtual room from all in-memory and DB state.
  Future<void> removeRoom(Client client, String matrixRoomId) async {
    final waId = _matrixToWa.remove(matrixRoomId);
    if (waId != null) _waToMatrix.remove(waId);
    try { await client.database.forgetRoom(matrixRoomId); } catch (_) {}
    client.rooms.removeWhere((r) => r.id == matrixRoomId);
    client.archivedRooms.removeWhere((r) => r.room.id == matrixRoomId);
  }

  /// Remove ALL WA virtual rooms from in-memory and DB state, and clear the
  /// Go bridge's persisted room list so they aren't restored on next start.
  Future<void> clearAllRooms(Client client) async {
    final matrixIds = _matrixToWa.keys.toList();
    for (final mid in matrixIds) {
      try { await client.database.forgetRoom(mid); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == mid);
      client.archivedRooms.removeWhere((r) => r.room.id == mid);
    }
    // Also remove the space room.
    if (_spaceId != null) {
      try { await client.database.forgetRoom(_spaceId!); } catch (_) {}
      client.rooms.removeWhere((r) => r.id == _spaceId);
      _spaceId = null;
    }
    _waToMatrix.clear();
    _matrixToWa.clear();
    _pendingMediaEvents.clear();
    _senderNames.clear();
    try {
      await TjenaBridge.instance.clearPersistedRooms();
    } catch (e) {
      Logs().w('[WaBridge] clearPersistedRooms failed: $e');
    }
  }

  // ── Bridge event dispatch ─────────────────────────────────────────────────────

  void _onBridgeEvent(BridgeEvent evt) {
    try {
      _onBridgeEventInner(evt);
    } catch (e, s) {
      Logs().w('[WaBridge] unhandled event error (${evt.type})', e, s);
    }
  }

  void _onBridgeEventInner(BridgeEvent evt) {
    switch (evt.type) {
      case BridgeEventType.state:
        final phone = evt.data['phone'] as String? ?? '';
        final connected = evt.data['connected'] as bool? ?? false;
        if (connected && phone.isNotEmpty && phone != _connectedPhone) {
          _connectedPhone = phone;
          _initSpace(phone);
        }

      case BridgeEventType.roomCreated:
        final data = evt.data['room'] as Map<String, dynamic>;
        _ensureRoom(
          data['id'] as String,
          data['name'] as String? ?? '',
          isDM: data['is_dm'] as bool? ?? true,
        );

      case BridgeEventType.roomUpdated:
        final waId = evt.data['room_id'] as String? ?? '';
        final name = evt.data['name'] as String? ?? '';
        final avatarUrl = evt.data['avatar_url'] as String? ?? '';
        if (name.isNotEmpty) {
          if (!_waToMatrix.containsKey(waId)) {
            _ensureRoom(waId, name, isDM: true);
          } else {
            _pushNameUpdate(waId, name);
          }
        }
        if (avatarUrl.isNotEmpty && _waToMatrix.containsKey(waId)) {
          _pushAvatarUpdate(waId, avatarUrl);
        }

      case BridgeEventType.message:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final eventData = evt.data['event'] as Map<String, dynamic>;
        if (!_waToMatrix.containsKey(waRoomId)) {
          final senderName = eventData['sender_name'] as String?;
          final fallbackName = senderName?.isNotEmpty == true
              ? senderName!
              : waRoomId.split('@').first;
          _ensureRoom(
            waRoomId,
            fallbackName,
            isDM: !waRoomId.endsWith('@g.us'),
          );
        }
        _pushMessage(waRoomId, eventData);

      case BridgeEventType.backfill:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final events =
            (evt.data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final e in events) {
          _pushMessage(waRoomId, e);
        }

      case BridgeEventType.mediaReady:
        final waRoomId = evt.data['room_id'] as String? ?? '';
        final eventId = evt.data['event_id'] as String? ?? '';
        final filePath = evt.data['file_path'] as String? ?? '';
        final mimetype = evt.data['mimetype'] as String? ?? 'application/octet-stream';
        final size = evt.data['size'] as int? ?? 0;
        if (filePath.isNotEmpty && eventId.isNotEmpty && _waToMatrix.containsKey(waRoomId)) {
          _pushMediaReady(waRoomId, eventId, filePath, mimetype, size);
        }

      case BridgeEventType.reaction:
        _pushReaction(evt.data);

      case BridgeEventType.typing:
        _pushTyping(evt.data);

      case BridgeEventType.receipt:
        _pushReceipt(evt.data);

      default:
        break;
    }
  }

  // ── Space management ──────────────────────────────────────────────────────────

  void _initSpace(String phone) {
    final client = _client;
    if (client?.userID == null) return;
    final name = 'WA-local ($phone)';

    if (_spaceId != null) {
      // Space already exists — just update the name.
      _pushNameUpdate(_spaceId!, name, isSpace: true);
      return;
    }
    _spaceId = _spaceRoomId;
    final myUserId = client!.userID!;
    final now = DateTime.now();

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        _spaceRoomId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomCreate,
              content: {
                'creator': myUserId,
                'room_version': '10',
                'type': 'm.space',
              },
              senderId: myUserId,
              eventId: '\$wa_space_create',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': name},
              senderId: myUserId,
              eventId: '\$wa_space_name',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomMember,
              content: {'membership': 'join'},
              senderId: myUserId,
              eventId: '\$wa_space_member',
              originServerTs: now,
              stateKey: myUserId,
            ),
            // Add all existing WA rooms as children.
            ..._waToMatrix.values.map(
              (mid) => MatrixEvent(
                type: 'm.space.child',
                content: {'via': ['local']},
                senderId: myUserId,
                eventId: '\$wa_spacechild_${_safe(mid)}',
                originServerTs: now,
                stateKey: mid,
              ),
            ),
          ],
          timeline: TimelineUpdate(events: [], limited: false),
        ),
      }),
    ));
  }

  void _addRoomToSpace(String matrixRoomId) {
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
              content: {'via': ['local']},
              senderId: client.userID!,
              eventId: '\$wa_spacechild_${_safe(matrixRoomId)}_${ts.millisecondsSinceEpoch}',
              originServerTs: ts,
              stateKey: matrixRoomId,
            ),
          ],
        ),
      }),
    ));
  }

  // ── Room lifecycle ────────────────────────────────────────────────────────────

  void _ensureRoom(String waId, String name, {required bool isDM}) {
    if (_waToMatrix.containsKey(waId)) {
      if (name.isNotEmpty) _pushNameUpdate(waId, name);
      return;
    }
    final matrixId = _toMatrixId(waId);
    _waToMatrix[waId] = matrixId;
    _matrixToWa[matrixId] = waId;
    _createRoom(matrixId, waId, name, isDM);
    if (_spaceId == null && _connectedPhone != null) {
      _initSpace(_connectedPhone!);
    }
    _addRoomToSpace(matrixId);
  }

  void _createRoom(String matrixId, String waId, String name, bool isDM) {
    final client = _client;
    if (client?.userID == null) return;
    final myUserId = client!.userID!;
    final now = DateTime.now();
    final token = client.prevBatch ?? '';
    final sid = _safe(waId);

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: token,
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          state: [
            MatrixEvent(
              type: EventTypes.RoomCreate,
              content: {'creator': myUserId, 'room_version': '10'},
              senderId: myUserId,
              eventId: '\$wacreate_$sid',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomName,
              content: {'name': name.isNotEmpty ? name : waId},
              senderId: myUserId,
              eventId: '\$waname_$sid',
              originServerTs: now,
              stateKey: '',
            ),
            MatrixEvent(
              type: EventTypes.RoomMember,
              content: {'membership': 'join'},
              senderId: myUserId,
              eventId: '\$wamember_$sid',
              originServerTs: now,
              stateKey: myUserId,
            ),
            MatrixEvent(
              type: _bridgeStateType,
              content: {'wa_room_id': waId, 'is_dm': isDM},
              senderId: myUserId,
              eventId: '\$wabridge_$sid',
              originServerTs: now,
              stateKey: '',
            ),
          ],
          timeline: TimelineUpdate(events: [], limited: false),
        ),
      }),
    ));
  }

  void _pushNameUpdate(String waIdOrSpaceId, String name, {bool isSpace = false}) {
    final matrixId = isSpace ? waIdOrSpaceId : _waToMatrix[waIdOrSpaceId];
    final client = _client;
    if (matrixId == null || client?.userID == null) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
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
              eventId: '\$waname_${_safe(waIdOrSpaceId)}_$ts',
              originServerTs: DateTime.now(),
              stateKey: '',
            ),
          ],
        ),
      }),
    ));
  }

  Future<void> _pushAvatarUpdate(String waId, String avatarHttpUrl) async {
    final matrixId = _waToMatrix[waId];
    final client = _client;
    if (matrixId == null || client?.userID == null) return;
    try {
      final response = await http.get(Uri.parse(avatarHttpUrl));
      if (response.statusCode != 200) return;
      final bytes = Uint8List.fromList(response.bodyBytes);
      // Store bytes in the Matrix database file cache under a fake mxc URI.
      // downloadMxcCached checks the cache first, so it never contacts a
      // homeserver for this URI.
      final mxcUri = Uri.parse('mxc://wa-local/${matrixId.hashCode.abs()}');
      await client!.database.storeFile(
        mxcUri,
        bytes,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
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
                senderId: client.userID!,
                eventId: '\$waavatar_${_safe(waId)}_${ts.millisecondsSinceEpoch}',
                originServerTs: ts,
                stateKey: '',
              ),
            ],
          ),
        }),
      ));
    } catch (e, s) {
      Logs().d('[WaBridge] avatar fetch failed for $waId', e, s);
    }
  }

  // ── Event injection ───────────────────────────────────────────────────────────

  void _pushMessage(String waRoomId, Map<String, dynamic> eventData) {
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null || client?.userID == null) return;
    final myUserId = client!.userID!;

    final eventId = eventData['id'] as String? ??
        '\$wa_${DateTime.now().millisecondsSinceEpoch}';
    final rawSender = eventData['sender'] as String? ?? '@wa_unknown:local';
    final body = eventData['body'] as String? ?? '';
    final msgtype = eventData['msgtype'] as String? ?? 'm.text';
    final tsSeconds = eventData['ts'] as int? ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final isOwn = eventData['is_own'] as bool? ?? false;
    final isBackfill = eventData['is_backfill'] as bool? ?? false;
    final geoUri = eventData['geo_uri'] as String?;

    // Build content map — extended for location and media msgtypes.
    final content = <String, dynamic>{
      'msgtype': msgtype,
      'body': body,
    };
    if (geoUri != null) {
      content['geo_uri'] = geoUri;
    }

    // For non-text, non-location msgtypes that need async media download,
    // remember enough to rebuild the event once media_ready arrives.
    final needsMedia = msgtype != 'm.text' && msgtype != 'm.location' && geoUri == null;
    if (needsMedia && !isBackfill) {
      _pendingMediaEvents[eventId] = {
        'waRoomId': waRoomId,
        'matrixId': matrixId,
        'sender': isOwn ? myUserId : rawSender,
        'ts': tsSeconds,
        'body': body,
        'msgtype': msgtype,
      };
    }

    // Inject/update the sender's display name so the chat shows the WA
    // nickname instead of the raw Matrix user ID. Re-inject only when the
    // name changes so we don't spam the sync handler.
    final senderName = eventData['sender_name'] as String?;
    if (!isOwn && senderName != null && senderName.isNotEmpty) {
      final nameKey = '$matrixId/$rawSender';
      if (_senderNames[nameKey] != senderName) {
        _senderNames[nameKey] = senderName;
        client.handleSync(SyncUpdate(
          nextBatch: client.prevBatch ?? '',
          rooms: RoomsUpdate(join: {
            matrixId: JoinedRoomUpdate(
              state: [
                MatrixEvent(
                  type: EventTypes.RoomMember,
                  content: {'membership': 'join', 'displayname': senderName},
                  senderId: rawSender,
                  eventId: '\$wamember_${_safe(rawSender)}_${_safe(matrixId)}',
                  originServerTs: DateTime.fromMillisecondsSinceEpoch(tsSeconds * 1000),
                  stateKey: rawSender,
                ),
              ],
            ),
          }),
        ));
      }
    }

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: EventTypes.Message,
                content: content,
                senderId: isOwn ? myUserId : rawSender,
                eventId: eventId,
                originServerTs: DateTime.fromMillisecondsSinceEpoch(
                  tsSeconds * 1000,
                ),
                roomId: matrixId,
              ),
            ],
            limited: false,
          ),
          unreadNotifications: (isOwn || isBackfill)
              ? null
              : UnreadNotificationCounts(notificationCount: 1),
        ),
      }),
    ));
  }

  Future<void> _pushMediaReady(
    String waRoomId,
    String eventId,
    String filePath,
    String mimetype,
    int size,
  ) async {
    final pending = _pendingMediaEvents.remove(eventId);
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null || client?.userID == null) return;
    try {
      final bytes = await File(filePath).readAsBytes();
      final mxcUri = Uri.parse('mxc://wa-media/${eventId.replaceAll(r'$', '')}');
      await client!.database.storeFile(
        mxcUri,
        bytes,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      final sender = pending?['sender'] as String? ?? '@wa_unknown:local';
      final ts = pending?['ts'] as int? ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
      final body = pending?['body'] as String? ?? '';
      final msgtype = pending?['msgtype'] as String? ?? 'm.file';

      _autoSaveMedia(bytes, body, msgtype);

      // Re-inject the event with the same ID to update content with media URL.
      // ignore: unawaited_futures
      client.handleSync(SyncUpdate(
        nextBatch: client.prevBatch ?? '',
        rooms: RoomsUpdate(join: {
          matrixId: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: [
                MatrixEvent(
                  type: EventTypes.Message,
                  content: {
                    'msgtype': msgtype,
                    'body': body,
                    'url': mxcUri.toString(),
                    'info': {'mimetype': mimetype, 'size': size},
                  },
                  senderId: sender,
                  eventId: eventId,
                  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
                  roomId: matrixId,
                ),
              ],
              limited: false,
            ),
          ),
        }),
      ));
    } catch (e, s) {
      Logs().d('[WaBridge] media_ready inject failed for $eventId', e, s);
    }
  }

  void _pushReaction(Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null || client == null || client.userID == null) return;

    final eventId = data['id'] as String? ??
        '\$wa_react_${DateTime.now().millisecondsSinceEpoch}';
    final rawSender = data['sender'] as String? ?? '@wa_unknown:local';
    final targetId = data['target_id'] as String? ?? '';
    final emoji = data['emoji'] as String? ?? '';
    final isOwn = rawSender.contains(_connectedPhone ?? '__none__');

    // ignore: unawaited_futures
    client.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent(
                type: 'm.reaction',
                content: {
                  'm.relates_to': {
                    'rel_type': 'm.annotation',
                    'event_id': '\$wa_$targetId',
                    'key': emoji,
                  },
                },
                senderId: isOwn ? client.userID! : rawSender,
                eventId: eventId,
                originServerTs: DateTime.now(),
                roomId: matrixId,
              ),
            ],
            limited: false,
          ),
        ),
      }),
    ));
  }

  void _pushTyping(Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null) return;

    final userId = data['user_id'] as String? ?? '@wa_unknown:local';
    final typing = data['typing'] as bool? ?? false;

    // ignore: unawaited_futures
    client?.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          ephemeral: [
            BasicEvent(
              type: 'm.typing',
              content: {
                'user_ids': typing ? [userId] : <String>[],
              },
            ),
          ],
        ),
      }),
    ));
  }

  void _pushReceipt(Map<String, dynamic> data) {
    final waRoomId = data['room_id'] as String? ?? '';
    final matrixId = _waToMatrix[waRoomId];
    final client = _client;
    if (matrixId == null) return;

    final userId = data['user_id'] as String? ?? '@wa_unknown:local';
    final eventId = data['event_id'] as String? ?? '';
    final ts = data['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (eventId.isEmpty) return;

    // ignore: unawaited_futures
    client?.handleSync(SyncUpdate(
      nextBatch: client.prevBatch ?? '',
      rooms: RoomsUpdate(join: {
        matrixId: JoinedRoomUpdate(
          ephemeral: [
            BasicEvent(
              type: 'm.receipt',
              content: {
                eventId: {
                  'm.read': {
                    userId: {'ts': ts},
                  },
                },
              },
            ),
          ],
        ),
      }),
    ));
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

  static void _autoSaveMedia(Uint8List bytes, String body, String msgtype) {
    if (kIsWeb || !PlatformInfos.isMobile) return;
    if (!AppSettings.autoSaveMedia.value) return;
    final isImage = msgtype == 'm.image';
    final isVideo = msgtype == 'm.video';
    if (!isImage && !isVideo) return;
    final file = isImage
        ? MatrixImageFile(bytes: bytes, name: body)
        : MatrixVideoFile(bytes: bytes, name: body);
    file.saveToGallery().catchError((_) => false);
  }
}
