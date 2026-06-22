// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:async/async.dart' as async;
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/size_string.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'matrix_file_extension.dart';

extension LocalizedBody on Event {
  Future<async.Result<MatrixFile?>> _getFile(BuildContext context) =>
      showFutureLoadingDialog(
        context: context,
        futureWithProgress: (onProgress) {
          final fileSize = infoMap['size'] is int
              ? infoMap['size'] as int
              : null;
          return downloadAndDecryptAttachment(
            onDownloadProgress: fileSize == null
                ? null
                : (bytes) => onProgress(bytes / fileSize),
          );
        },
      );

  Future<void> saveFile(BuildContext context) async {
    final matrixFile = await _getFile(context);
    if (!context.mounted) return;

    final file = matrixFile.result;
    if (file == null) return;
    final autoSave = !kIsWeb &&
        PlatformInfos.isMobile &&
        AppSettings.autoSaveMedia.value &&
        (file is MatrixImageFile || file is MatrixVideoFile);
    if (autoSave) {
      file.saveToDevice(context);
    } else {
      file.save(context);
    }
  }

  Future<void> autoSaveToDevice(BuildContext context) async =>
      autoSaveBackground();

  /// Auto-save image/video to gallery without requiring a BuildContext.
  Future<void> autoSaveBackground() async {
    if (kIsWeb || !PlatformInfos.isMobile) return;
    if (!AppSettings.autoSaveMedia.value) return;
    if (messageType != MessageTypes.Image &&
        messageType != MessageTypes.Video) {
      return;
    }

    final savedKey = 'auto_saved_$eventId';
    if (AppSettings.store.getBool(savedKey) == true) return;
    await AppSettings.store.setBool(savedKey, true);

    try {
      final file = await downloadAndDecryptAttachment();
      // Name the saved file "<chatType>_<full timestamp>.<ext>" so the gallery
      // shows where it came from and when.
      final roomId = room.id;
      final chatType = roomId.startsWith('!wa_')
          ? 'wa'
          : roomId.startsWith('!sig_')
              ? 'signal'
              : 'matrix';
      final fileName = MatrixFileExtension.galleryName(
        chatType,
        mimeType: attachmentMimetype,
        originalName: file.name,
        video: messageType == MessageTypes.Video,
      );
      final saved = await file.saveToGallery(fileName: fileName);
      if (!saved) await AppSettings.store.remove(savedKey);
    } catch (_) {
      await AppSettings.store.remove(savedKey);
    }
  }

  Future<void> shareFile(BuildContext context) async {
    final matrixFile = await _getFile(context);
    if (!context.mounted) return;

    matrixFile.result?.share(context);
  }

  bool get isAttachmentSmallEnough =>
      infoMap['size'] is int &&
      (infoMap['size'] as int) < room.client.database.maxFileSize;

  bool get isThumbnailSmallEnough =>
      thumbnailInfoMap['size'] is int &&
      (thumbnailInfoMap['size'] as int) < room.client.database.maxFileSize;

  bool get showThumbnail =>
      [
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Video,
      ].contains(messageType) &&
      (kIsWeb ||
          isAttachmentSmallEnough ||
          isThumbnailSmallEnough ||
          (content['url'] is String));

  String? get sizeString => content
      .tryGetMap<String, Object?>('info')
      ?.tryGet<int>('size')
      ?.sizeString;
}
