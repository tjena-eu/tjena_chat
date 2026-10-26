// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'platform_infos.dart';

/// Decodes the first frame of a video so the timeline can show a real preview
/// for videos that arrive without one.
///
/// Matrix clients are not required to upload a `thumbnail_url`, and WhatsApp
/// only sometimes embeds a JPEG preview, so a lot of videos would otherwise
/// render as a flat blur hash. Generated frames are cached in the Matrix file
/// store under a deterministic `mxc://video-thumb/<eventId>` URI, which keeps
/// them across restarts without touching any server.
abstract class VideoThumbnailGenerator {
  /// Videos that are not cached locally yet are only fetched for a preview when
  /// they are at most this large — decoding a frame is not worth a big download
  /// on mobile data.
  static const int maxDownloadSize = 10 * 1024 * 1024;

  /// Even a locally cached video has to be read into memory and copied to a
  /// temp file before a frame can be pulled out of it, so huge files are left
  /// with their blur hash.
  static const int maxDecodeSize = 64 * 1024 * 1024;

  static final Map<String, Uint8List?> _cache = {};
  static final Map<String, Future<Uint8List?>> _running = {};

  /// Frame decoding runs one video at a time: scrolling past a chat full of
  /// videos must not kick off a dozen parallel decodes.
  static Future<void> _queue = Future.value();

  static Uri _cacheUri(Event event) =>
      Uri.parse('mxc://video-thumb/${event.eventId.replaceAll(r'$', '')}');

  /// The already generated frame for [event], if there is one. Lets callers
  /// paint the preview on the first build instead of flashing a placeholder.
  static Uint8List? cached(Event event) => _cache[event.eventId];

  /// Returns the first frame of [event]'s video, or `null` if it cannot be
  /// produced (unsupported platform, video not available, decode failure).
  static Future<Uint8List?> resolve(Event event) {
    final eventId = event.eventId;
    final cached = _cache[eventId];
    if (cached != null) return Future.value(cached);
    return _running[eventId] ??= _resolve(
      event,
    ).whenComplete(() => _running.remove(eventId));
  }

  static Future<Uint8List?> _resolve(Event event) async {
    final client = event.room.client;
    final cacheUri = _cacheUri(event);

    final stored = await client.database.getFile(cacheUri);
    if (stored != null && stored.isNotEmpty) {
      return _cache[event.eventId] = stored;
    }

    // LightCompressor is an Android/iOS plugin; there is no frame decoder on
    // the other platforms.
    if (!PlatformInfos.isMobile) return null;

    final thumbnail = await _enqueue(() => _decodeFirstFrame(event));
    if (thumbnail == null || thumbnail.isEmpty) return null;

    await client.database.storeFile(
      cacheUri,
      thumbnail,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    return _cache[event.eventId] = thumbnail;
  }

  /// Runs [task] after every decode queued before it.
  static Future<T?> _enqueue<T>(Future<T?> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<Uint8List?> _decodeFirstFrame(Event event) async {
    final videoBytes = await _videoBytes(event);
    if (videoBytes == null || videoBytes.isEmpty) return null;

    File? tempFile;
    try {
      final tempDir = await getTemporaryDirectory();
      tempFile = File(
        '${tempDir.path}/video_thumb_${event.eventId.hashCode}.tmp',
      );
      await tempFile.writeAsBytes(videoBytes);
      final thumbnailPath = await LightCompressor().getVideoThumbnail(
        tempFile.path,
      );
      final thumbnailFile = File(thumbnailPath);
      final bytes = await thumbnailFile.readAsBytes();
      try {
        await thumbnailFile.delete();
      } catch (_) {}
      return bytes;
    } catch (e, s) {
      Logs().w('Unable to generate a video thumbnail', e, s);
      return null;
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }
  }

  /// Media hosted by a local bridge rather than by a homeserver: these mxc URIs
  /// only ever resolve against the local file store, so there is nothing to
  /// download when they are missing.
  static const Set<String> _localMediaHosts = {'sig-local', 'video-thumb'};

  /// The video itself, from the local file store when possible. Built-in
  /// Signal bridge media always is; a remote Matrix upload is downloaded
  /// only when it is small enough to be worth it.
  static Future<Uint8List?> _videoBytes(Event event) async {
    try {
      final size = event.infoMap.tryGet<int>('size');
      if (!await event.isAttachmentInLocalStore()) {
        final host = event.attachmentOrThumbnailMxcUrl()?.host;
        if (host == null || _localMediaHosts.contains(host)) return null;
        if (size == null || size > maxDownloadSize) return null;
      } else if (size != null && size > maxDecodeSize) {
        return null;
      }
      final file = await event.downloadAndDecryptAttachment();
      return file.bytes;
    } catch (e, s) {
      Logs().v('Video not available for thumbnail generation', e, s);
      return null;
    }
  }
}
