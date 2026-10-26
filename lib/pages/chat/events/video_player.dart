// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';
import 'dart:typed_data';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/media_auto_download.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/blur_hash.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../../utils/video_thumbnail_generator.dart';
import '../../image_viewer/image_viewer.dart';

class EventVideoPlayer extends StatelessWidget {
  final Event event;
  final Timeline? timeline;
  final Color? textColor;
  final Color? linkColor;

  /// Widest the preview may get. The timeline passes the message bubble's
  /// width so a video fills its bubble instead of shrinking it.
  final double? maxWidth;

  const EventVideoPlayer(
    this.event, {
    this.timeline,
    this.textColor,
    this.linkColor,
    this.maxWidth,
    super.key,
  });

  static const String fallbackBlurHash = 'L5H2EC=PM+yV0g-mq.wG9c010J}I';

  @override
  Widget build(BuildContext context) {
    final supportsVideoPlayer = PlatformInfos.supportsVideoPlayer;

    final blurHash =
        (event.infoMap as Map<String, dynamic>).tryGet<String>(
          'xyz.amorgan.blurhash',
        ) ??
        fallbackBlurHash;
    final fileDescription = event.fileDescription;
    const maxDimension = 300.0;
    final infoMap = event.content.tryGetMap<String, Object?>('info');
    final videoWidth = infoMap?.tryGet<int>('w') ?? maxDimension;
    final videoHeight = infoMap?.tryGet<int>('h') ?? maxDimension;

    final double width, height;
    final maxWidth = this.maxWidth;
    if (maxWidth != null) {
      // Bubble-sized: clamp extreme aspect ratios so a portrait clip cannot
      // stretch the message into a tall sliver.
      width = maxWidth;
      height = (maxWidth * videoHeight / videoWidth).clamp(
        maxWidth * 0.5,
        maxWidth * 1.4,
      );
    } else {
      final modifier = max(videoWidth, videoHeight) / maxDimension;
      width = videoWidth / modifier;
      height = videoHeight / modifier;
    }

    final durationInt = infoMap?.tryGet<int>('duration');
    final duration = durationInt == null
        ? null
        : Duration(milliseconds: durationInt);

    final Widget preview;
    if (!MediaAutoDownload.enabledFor(event.room.id)) {
      preview = BlurHash(
        blurhash: blurHash,
        width: width,
        height: height,
        fit: BoxFit.cover,
      );
    } else {
      // A video without a usable thumbnail falls back to its own first frame.
      final firstFrame = FirstFrameThumbnail(
        event: event,
        width: width,
        height: height,
        blurHash: blurHash,
      );
      preview = event.hasThumbnail
          ? MxcImage(
              event: event,
              isThumbnail: true,
              width: width,
              height: height,
              fit: BoxFit.cover,
              // The sender's thumbnail may be advertised but missing (bridged
              // media in particular), hence the same fallback here.
              placeholder: (context) => firstFrame,
            )
          : firstFrame;
    }

    return Column(
      mainAxisSize: .min,
      spacing: 8,
      children: [
        Material(
          color: Colors.black,
          borderRadius: BorderRadius.circular(AppConfig.borderRadius),
          child: InkWell(
            onTap: () async {
              return supportsVideoPlayer
                  ? Navigator.of(context).push(
                      PageRouteBuilder(
                        opaque: false,
                        barrierColor: Colors.transparent,
                        pageBuilder: (_, _, _) => ImageViewer(
                          event,
                          timeline: timeline,
                          outerContext: context,
                        ),
                        // No FadeTransition: Hero already provides a smooth
                        // animation from bubble to fullscreen. A fade on top
                        // of Hero causes the "double-open flash".
                        transitionsBuilder: (_, _, _, child) => child,
                      ),
                    )
                  : event.saveFile(context);
            },
            borderRadius: BorderRadius.circular(AppConfig.borderRadius),
            child: SizedBox(
              width: width,
              height: height,
              child: Hero(
                tag: event.eventId,
                child: Stack(
                  children: [
                    preview,
                    Center(
                      child: CircleAvatar(
                        child: supportsVideoPlayer
                            ? const Icon(Icons.play_arrow_outlined)
                            : const Icon(Icons.file_download_outlined),
                      ),
                    ),
                    if (duration != null)
                      Positioned(
                        bottom: 8,
                        left: 16,
                        child: Text(
                          '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: TextStyle(
                            color: Colors.white,
                            backgroundColor: Colors.black.withAlpha(32),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (fileDescription != null && textColor != null && linkColor != null)
          SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Linkify(
                text: fileDescription,
                textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
                style: TextStyle(
                  color: textColor,
                  fontSize: AppConfig.messageFontSize,
                ),
                options: const LinkifyOptions(humanize: false),
                linkStyle: TextStyle(
                  color: linkColor,
                  fontSize: AppConfig.messageFontSize,
                  decoration: TextDecoration.underline,
                  decorationColor: linkColor,
                ),
                onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
              ),
            ),
          ),
      ],
    );
  }
}

/// Preview for a video that ships without a usable thumbnail: decodes the first
/// frame locally (see [VideoThumbnailGenerator]) and shows the blur hash until
/// it is ready — or forever, if the frame cannot be produced.
class FirstFrameThumbnail extends StatefulWidget {
  final Event event;
  final double width;
  final double height;
  final String blurHash;

  const FirstFrameThumbnail({
    required this.event,
    required this.width,
    required this.height,
    required this.blurHash,
    super.key,
  });

  @override
  State<FirstFrameThumbnail> createState() => _FirstFrameThumbnailState();
}

class _FirstFrameThumbnailState extends State<FirstFrameThumbnail> {
  Uint8List? _frame;

  @override
  void initState() {
    super.initState();
    _frame = VideoThumbnailGenerator.cached(widget.event);
    if (_frame == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final frame = await VideoThumbnailGenerator.resolve(widget.event);
    if (frame == null || !mounted) return;
    setState(() => _frame = frame);
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    if (frame == null) {
      return BlurHash(
        blurhash: widget.blurHash,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
      );
    }
    return Image.memory(
      frame,
      width: widget.width,
      height: widget.height,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      errorBuilder: (context, e, s) => BlurHash(
        blurhash: widget.blurHash,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
      ),
    );
  }
}
