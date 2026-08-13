// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/pages/image_viewer/image_viewer_view.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/show_scaffold_dialog.dart';
import 'package:fluffychat/widgets/share_scaffold_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../utils/matrix_sdk_extensions/event_extension.dart';

class ImageViewer extends StatefulWidget {
  final Event event;
  final Timeline? timeline;
  final BuildContext outerContext;

  const ImageViewer(
    this.event, {
    required this.outerContext,
    this.timeline,
    super.key,
  });

  @override
  ImageViewerController createState() => ImageViewerController();
}

class ImageViewerController extends State<ImageViewer> {
  final FocusNode focusNode = FocusNode();

  bool backgroundVisible = false;

  @override
  void initState() {
    super.initState();
    allEvents =
        widget.timeline?.events
            .where(
              (event) => {
                MessageTypes.Image,
                MessageTypes.Sticker,
                if (PlatformInfos.supportsVideoPlayer) MessageTypes.Video,
              }.contains(event.messageType),
            )
            .toList()
            .reversed
            .toList() ??
        [widget.event];
    var index = allEvents.indexWhere(
      (event) => event.eventId == widget.event.eventId,
    );
    if (index < 0) index = 0;
    pageController = PageController(initialPage: index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      currentEvent.autoSaveToDevice(widget.outerContext);
      if (mounted) setState(() => backgroundVisible = true);
    });
  }

  late final PageController pageController;

  late final List<Event> allEvents;

  void onKeyEvent(KeyEvent event) {
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        if (canGoBack) prevImage();
        break;
      case LogicalKeyboardKey.arrowDown:
        if (canGoNext) nextImage();
        break;
    }
  }

  Future<void> prevImage() async {
    await pageController.previousPage(
      duration: FluffyThemes.animationDuration,
      curve: FluffyThemes.animationCurve,
    );
    if (!mounted) return;
    setState(() {});
    currentEvent.autoSaveToDevice(context);
  }

  Future<void> nextImage() async {
    await pageController.nextPage(
      duration: FluffyThemes.animationDuration,
      curve: FluffyThemes.animationCurve,
    );
    if (!mounted) return;
    setState(() {});
    currentEvent.autoSaveToDevice(context);
  }

  /// Whether the currently visible image is zoomed in.
  ///
  /// While zoomed, the vertical [PageView] must not scroll: dragging has to pan
  /// the image instead of flicking to the next one.
  final ValueNotifier<bool> isZoomed = ValueNotifier(false);

  final Set<Object> _zoomedPages = {};
  final Set<VoidCallback> _resetZoomCallbacks = {};

  void setZoomed(Object page, bool zoomed) {
    zoomed ? _zoomedPages.add(page) : _zoomedPages.remove(page);
    isZoomed.value = _zoomedPages.isNotEmpty;
  }

  /// Same as [setZoomed] with `false`, but safe to call from `dispose()`: the
  /// widget tree is locked there, so the notifier is only updated once the
  /// current frame is finished.
  void forgetZoomed(Object page) {
    _zoomedPages.remove(page);
    if (isZoomed.value == _zoomedPages.isNotEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      isZoomed.value = _zoomedPages.isNotEmpty;
    });
  }

  void registerZoomReset(VoidCallback callback) =>
      _resetZoomCallbacks.add(callback);

  void unregisterZoomReset(VoidCallback callback) =>
      _resetZoomCallbacks.remove(callback);

  /// Swiping to another image: drop any zoom so every image starts fitted, and
  /// refresh the previous/next buttons.
  void onPageChanged(int _) {
    for (final reset in _resetZoomCallbacks.toList()) {
      reset();
    }
    if (!mounted) return;
    setState(() {});
    currentEvent.autoSaveToDevice(context);
  }

  @override
  void dispose() {
    isZoomed.dispose();
    focusNode.dispose();
    pageController.dispose();
    super.dispose();
  }

  int get _index => pageController.page?.toInt() ?? 0;

  Event get currentEvent => allEvents[_index];

  bool get canGoNext => _index < allEvents.length - 1;

  bool get canGoBack => _index > 0;

  /// Forward this image to another room.
  void forwardAction() => showScaffoldDialog(
    context: context,
    builder: (context) =>
        ShareScaffoldDialog(items: [ContentShareItem(currentEvent.content)]),
  );

  /// Save this file with a system call.
  void saveFileAction(BuildContext context) => currentEvent.saveFile(context);

  /// Save this file with a system call.
  void shareFileAction(BuildContext context) => currentEvent.shareFile(context);

  static const maxScaleFactor = 1.5;

  /// Go back if user swiped it away
  void onInteractionEnds(ScaleEndDetails endDetails) {
    if (PlatformInfos.usesTouchscreen == false) {
      if (endDetails.velocity.pixelsPerSecond.dy >
          MediaQuery.sizeOf(context).height * maxScaleFactor) {
        Navigator.of(context, rootNavigator: false).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) => ImageViewerView(this);
}
