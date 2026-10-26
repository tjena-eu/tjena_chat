// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/image_viewer/pointers_listener.dart';
import 'package:fluffychat/pages/image_viewer/video_player.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/hover_builder.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'image_viewer.dart';

class ImageViewerView extends StatelessWidget {
  final ImageViewerController controller;

  const ImageViewerView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final iconButtonStyle = IconButton.styleFrom(
      backgroundColor: Colors.black.withAlpha(200),
      foregroundColor: Colors.white,
    );
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        color: controller.backgroundVisible
            ? Colors.black.withAlpha(128)
            : Colors.transparent,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            elevation: 0,
            leading: IconButton(
              style: iconButtonStyle,
              icon: const Icon(Icons.close),
              onPressed: Navigator.of(context).pop,
              color: Colors.white,
              tooltip: L10n.of(context).close,
            ),
            backgroundColor: Colors.transparent,
            actions: [
              IconButton(
                style: iconButtonStyle,
                icon: const Icon(Icons.reply_outlined),
                onPressed: controller.forwardAction,
                color: Colors.white,
                tooltip: L10n.of(context).share,
              ),
              const SizedBox(width: 8),
              IconButton(
                style: iconButtonStyle,
                icon: const Icon(Icons.download_outlined),
                onPressed: () => controller.saveFileAction(context),
                color: Colors.white,
                tooltip: L10n.of(context).downloadFile,
              ),
              const SizedBox(width: 8),
              if (PlatformInfos.isMobile)
                // Use builder context to correctly position the share dialog on iPad
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Builder(
                    builder: (context) => IconButton(
                      style: iconButtonStyle,
                      onPressed: () => controller.shareFileAction(context),
                      tooltip: L10n.of(context).share,
                      color: Colors.white,
                      icon: Icon(Icons.adaptive.share_outlined),
                    ),
                  ),
                ),
            ],
          ),
          body: HoverBuilder(
            builder: (context, hovered) => Stack(
              children: [
                KeyboardListener(
                  focusNode: controller.focusNode,
                  onKeyEvent: controller.onKeyEvent,
                  child: PointersListener(
                    builder: (context, moreThanOnePointer) =>
                        ValueListenableBuilder<bool>(
                          valueListenable: controller.isZoomed,
                          builder: (context, isZoomed, _) => PageView.builder(
                            // While zoomed in (or pinching), a drag pans the
                            // image instead of flicking to the next one.
                            physics: !moreThanOnePointer && !isZoomed
                                ? BouncingScrollPhysics()
                                : NeverScrollableScrollPhysics(),
                            scrollDirection: Axis.horizontal,
                            controller: controller.pageController,
                            onPageChanged: controller.onPageChanged,
                            itemCount: controller.allEvents.length,
                            itemBuilder: (context, i) {
                              final event = controller.allEvents[i];
                              switch (event.messageType) {
                                case MessageTypes.Video:
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 52.0),
                                    child: Center(
                                      child: GestureDetector(
                                        // Ignore taps to not go back here:
                                        onTap: () {},
                                        child: EventVideoPlayer(event),
                                      ),
                                    ),
                                  );
                                case MessageTypes.Image:
                                case MessageTypes.Sticker:
                                default:
                                  return ZoomableImage(
                                    controller: controller,
                                    child: Center(
                                      child: Hero(
                                        tag: event.eventId,
                                        child: MxcImage(
                                          key: ValueKey(event.eventId),
                                          event: event,
                                          fit: BoxFit.contain,
                                          isThumbnail: false,
                                          animated: true,
                                          cacheKey: '${event.eventId}_full',
                                          // Show the bubble's already-decoded
                                          // thumbnail (same cacheKey) while the
                                          // full image loads, so the Hero
                                          // animation doesn't flash black.
                                          placeholder: (context) => MxcImage(
                                            event: event,
                                            fit: BoxFit.contain,
                                            isThumbnail: true,
                                            cacheKey: '${event.eventId}_thumb',
                                            cacheName: event.room.id,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                              }
                            },
                          ),
                        ),
                  ),
                ),
                if (hovered) ...[
                  if (controller.canGoBack)
                    Align(
                      alignment: .centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: IconButton(
                          style: iconButtonStyle,
                          tooltip: L10n.of(context).previous,
                          icon: const Icon(Icons.keyboard_arrow_left_outlined),
                          onPressed: controller.prevImage,
                        ),
                      ),
                    ),
                  if (controller.canGoNext)
                    Align(
                      alignment: .centerRight,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: IconButton(
                          style: iconButtonStyle,
                          tooltip: L10n.of(context).next,
                          icon: const Icon(Icons.keyboard_arrow_right_outlined),
                          onPressed: controller.nextImage,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pinch- and double-tap-zoomable wrapper around a full screen image.
///
/// [InteractiveViewer] alone only gives pinch zoom; this adds double tap to
/// zoom towards the tapped point (animated), and reports the zoom state back to
/// the [ImageViewerController] so the surrounding [PageView] stops scrolling
/// while the user pans a zoomed image.
class ZoomableImage extends StatefulWidget {
  final ImageViewerController controller;
  final Widget child;

  const ZoomableImage({
    required this.controller,
    required this.child,
    super.key,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  static const double _minScale = 1.0;
  static const double _maxScale = 10.0;
  static const double _doubleTapScale = 2.5;

  final TransformationController _transformation = TransformationController();
  late final AnimationController _animationController;
  Animation<Matrix4>? _zoomAnimation;
  Offset? _doubleTapPosition;

  bool get _isZoomed => _transformation.value.getMaxScaleOnAxis() > 1.01;

  @override
  void initState() {
    super.initState();
    _animationController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addListener(() {
          final matrix = _zoomAnimation?.value;
          if (matrix != null) _transformation.value = matrix;
        });
    _transformation.addListener(_onTransformationChanged);
    widget.controller.registerZoomReset(_resetZoom);
  }

  @override
  void dispose() {
    widget.controller
      ..unregisterZoomReset(_resetZoom)
      ..forgetZoomed(this);
    _transformation.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _onTransformationChanged() =>
      widget.controller.setZoomed(this, _isZoomed);

  void _animateTo(Matrix4 target) {
    _zoomAnimation = Matrix4Tween(begin: _transformation.value, end: target)
        .animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );
    _animationController.forward(from: 0);
  }

  void _resetZoom() {
    _animationController.stop();
    _zoomAnimation = null;
    _transformation.value = Matrix4.identity();
  }

  void _onDoubleTap() {
    if (_isZoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    final position = _doubleTapPosition ?? Offset.zero;
    _animateTo(
      Matrix4.identity()
        ..translateByDouble(
          -position.dx * (_doubleTapScale - 1),
          -position.dy * (_doubleTapScale - 1),
          0,
          1,
        )
        ..scaleByDouble(_doubleTapScale, _doubleTapScale, _doubleTapScale, 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transformation,
      minScale: _minScale,
      maxScale: _maxScale,
      onInteractionEnd: widget.controller.onInteractionEnds,
      child: GestureDetector(
        // Ignore single taps to not go back here:
        onTap: () {},
        onDoubleTapDown: (details) =>
            _doubleTapPosition = details.localPosition,
        onDoubleTap: _onDoubleTap,
        child: widget.child,
      ),
    );
  }
}
