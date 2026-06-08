// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/client_stories_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

enum _AddStoryAction { photo, camera, video, text }

/// Lets the user post a story (image / video / text). The post is sent to their
/// MSC3588 stories room (created on first use, inviting direct-chat contacts).
Future<void> showAddStorySheet(BuildContext context) async {
  final action = await showModalActionPopup<_AddStoryAction>(
    context: context,
    title: 'Add to your story',
    actions: [
      AdaptiveModalAction(
        value: _AddStoryAction.photo,
        label: 'Photo from gallery',
        icon: Icon(Icons.photo_outlined),
      ),
      AdaptiveModalAction(
        value: _AddStoryAction.camera,
        label: 'Take a photo',
        icon: Icon(Icons.camera_alt_outlined),
      ),
      AdaptiveModalAction(
        value: _AddStoryAction.video,
        label: 'Video from gallery',
        icon: Icon(Icons.video_camera_back_outlined),
      ),
      AdaptiveModalAction(
        value: _AddStoryAction.text,
        label: 'Text',
        icon: Icon(Icons.notes_outlined),
      ),
    ],
  );
  if (action == null || !context.mounted) return;

  final client = Matrix.of(context).client;

  // Text stories: ask for text, then post.
  if (action == _AddStoryAction.text) {
    final text = await showTextInputDialog(
      context: context,
      title: 'Text story',
      hintText: 'What\'s on your mind?',
      maxLines: 5,
    );
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    final room = await showFutureLoadingDialog(
      context: context,
      future: client.getOrCreateMyStoriesRoom,
    );
    await room.result?.sendTextEvent(text.trim());
    return;
  }

  // Media stories: pick a file, then reuse the normal send-file dialog (handles
  // conversion, compression and an optional caption) targeting the stories room.
  final picker = ImagePicker();
  XFile? file;
  switch (action) {
    case _AddStoryAction.photo:
      file = await picker.pickImage(source: ImageSource.gallery);
      break;
    case _AddStoryAction.camera:
      file = await picker.pickImage(source: ImageSource.camera);
      break;
    case _AddStoryAction.video:
      file = await picker.pickVideo(source: ImageSource.gallery);
      break;
    case _AddStoryAction.text:
      break;
  }
  if (file == null || !context.mounted) return;
  final pickedFile = file;

  final roomResult = await showFutureLoadingDialog(
    context: context,
    future: client.getOrCreateMyStoriesRoom,
  );
  final room = roomResult.result;
  if (room == null || !context.mounted) return;

  await showAdaptiveDialog(
    context: context,
    builder: (c) => SendFileDialog(
      files: [pickedFile],
      room: room,
      outerContext: context,
      threadRootEventId: null,
      threadLastEventId: null,
    ),
  );
}
