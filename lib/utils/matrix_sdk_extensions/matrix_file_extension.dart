// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/size_string.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:matrix/matrix.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

extension MatrixFileExtension on MatrixFile {
  Future<void> save(BuildContext context) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    final downloadPath = await FilePicker.saveFile(
      dialogTitle: l10n.saveFile,
      fileName: name,
      type: filePickerFileType,
      bytes: bytes,
    );
    if (downloadPath == null) return;

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(l10n.fileHasBeenSavedAt(downloadPath)),
        action: SnackBarAction(
          label: l10n.open,
          onPressed: () => OpenFile.open(downloadPath),
        ),
      ),
    );
  }

  /// Save image/video to the device gallery without any UI interaction.
  /// Returns true on success. Throws on failure — caller decides how to handle.
  static const _galAlbum = 'tjenachat';

  /// Save to the gallery. [fileName], when given, becomes the saved file's name
  /// (e.g. "wa_2026-06-22_09-30-15.jpg"); otherwise the file's own [name] is
  /// used. Saving always goes through a temp file so the chosen name is honored
  /// (gal cannot name raw image bytes).
  Future<bool> saveToGallery({String? fileName}) async {
    const imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'};
    const videoExts = {'mp4', 'mov', 'avi', 'mkv', 'webm', '3gp', 'm4v'};

    final outName = fileName ?? name;
    final ext = outName.toLowerCase().split('.').last;
    final isImage = this is MatrixImageFile || imageExts.contains(ext);
    final isVideo = this is MatrixVideoFile || videoExts.contains(ext);
    if (!isImage && !isVideo) return false;

    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/$outName');
    await tempFile.writeAsBytes(bytes);
    try {
      if (isVideo) {
        await Gal.putVideo(tempFile.path, album: _galAlbum);
      } else {
        await Gal.putImage(tempFile.path, album: _galAlbum);
      }
    } finally {
      try { await tempFile.delete(); } catch (_) {}
    }
    return true;
  }

  /// Build a gallery filename "<chatType>_<full timestamp>.<ext>", e.g.
  /// "wa_2026-06-22_09-30-15.jpg". chatType ∈ {matrix, wa, signal}.
  static String galleryName(
    String chatType, {
    String? mimeType,
    String? originalName,
    bool video = false,
  }) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts =
        '${now.year}-${two(now.month)}-${two(now.day)}_${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
    var ext = '';
    if (mimeType != null && mimeType.contains('/')) {
      ext = mimeType.split('/').last.split(';').first;
      if (ext == 'jpeg') ext = 'jpg';
      if (ext == 'quicktime') ext = 'mov';
    }
    if (ext.isEmpty && originalName != null && originalName.contains('.')) {
      ext = originalName.toLowerCase().split('.').last;
    }
    if (ext.isEmpty) ext = video ? 'mp4' : 'jpg';
    return '${chatType}_$ts.$ext';
  }

  Future<void> saveToDevice(BuildContext context) async {
    if (kIsWeb || !PlatformInfos.isMobile) {
      return save(context);
    }
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    bool saved;
    try {
      saved = await saveToGallery();
    } catch (_) {
      if (!context.mounted) return;
      return save(context);
    }
    if (!saved) {
      if (!context.mounted) return;
      return save(context);
    }
    if (!context.mounted) return;
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text(l10n.savedToGallery)),
    );
  }

  FileType get filePickerFileType {
    if (this is MatrixImageFile) return FileType.image;
    if (this is MatrixAudioFile) return FileType.audio;
    if (this is MatrixVideoFile) return FileType.video;
    return FileType.any;
  }

  Future<void> share(BuildContext context) async {
    // Workaround for iPad from
    // https://github.com/fluttercommunity/plus_plugins/tree/main/packages/share_plus/share_plus#ipad
    final box = context.findRenderObject() as RenderBox?;

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: name, mimeType: mimeType)],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
    return;
  }

  MatrixFile get detectFileType {
    if (msgType == MessageTypes.Image) {
      return MatrixImageFile(bytes: bytes, name: name);
    }
    if (msgType == MessageTypes.Video) {
      return MatrixVideoFile(bytes: bytes, name: name);
    }
    if (msgType == MessageTypes.Audio) {
      return MatrixAudioFile(bytes: bytes, name: name);
    }
    return this;
  }

  String get sizeString => size.sizeString;
}
