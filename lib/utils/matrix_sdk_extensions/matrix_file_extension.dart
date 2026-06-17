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
  Future<bool> saveToGallery() async {
    if (this is MatrixImageFile) {
      await Gal.putImageBytes(bytes);
      return true;
    } else if (this is MatrixVideoFile) {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$name');
      await tempFile.writeAsBytes(bytes);
      await Gal.putVideo(tempFile.path);
      await tempFile.delete();
      return true;
    }
    return false;
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
