// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/file_send_status_indicator.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/media_auto_download.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:matrix/matrix.dart';

import '../../../widgets/blur_hash.dart';

class ImageBubble extends StatefulWidget {
  final Event event;
  final bool tapToView;
  final BoxFit fit;
  final Color? backgroundColor;
  final Color? textColor;
  final Color? linkColor;
  final bool thumbnailOnly;
  final bool animated;
  final double width;

  /// `null` lets the image size itself from its own aspect ratio once decoded,
  /// for events whose `info` carries no dimensions.
  final double? height;
  final void Function()? onTap;
  final BorderRadius? borderRadius;
  final Timeline? timeline;

  /// Tallest an image may get relative to its width. Only bites when [height]
  /// is `null`, i.e. when the event carries no dimensions of its own.
  static const double maxAspectRatio = 1.4;

  const ImageBubble(
    this.event, {
    this.tapToView = true,
    this.backgroundColor,
    this.fit = BoxFit.contain,
    this.thumbnailOnly = true,
    this.width = 400,
    this.height = 300,
    this.animated = false,
    this.onTap,
    this.borderRadius,
    this.timeline,
    this.textColor,
    this.linkColor,
    super.key,
  });

  @override
  State<ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<ImageBubble> {
  /// Set when the user taps a not-auto-loaded image, revealing just that one.
  bool _revealed = false;

  /// Reveal this one image.
  Future<void> _reveal() async {
    final event = widget.event;
    setState(() => _revealed = true);
    // Saving is tied to the download, so a tap-to-load image still lands in the
    // gallery when the chat has auto-save on.
    // ignore: unawaited_futures
    event.autoSaveBackground();
  }

  @override
  void initState() {
    super.initState();
    // Flipping the chat's auto-download setting must take effect on the events
    // already on screen, not only on the next rebuild.
    MediaAutoDownload.revision.addListener(_onAutoDownloadChanged);
  }

  @override
  void dispose() {
    MediaAutoDownload.revision.removeListener(_onAutoDownloadChanged);
    super.dispose();
  }

  void _onAutoDownloadChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = widget.event;
    final width = widget.width;
    final height = widget.height;
    final fit = widget.fit;
    final thumbnailOnly = widget.thumbnailOnly;
    final animated = widget.animated;

    var borderRadius =
        widget.borderRadius ?? BorderRadius.circular(AppConfig.borderRadius);

    final fileDescription = event.fileDescription;
    final textColor = widget.textColor;

    if (fileDescription != null) {
      borderRadius = borderRadius.copyWith(
        bottomLeft: Radius.zero,
        bottomRight: Radius.zero,
      );
    }
    final fileSendingStatus = event.fileSendingStatus;

    // Auto-download is per chat (falling back to the global thumbnail setting).
    // When it's off the bubble stays a blurhash until tapped once — the first
    // tap loads this one image, a second tap opens the viewer as usual.
    final autoLoad = MediaAutoDownload.enabledFor(event.room.id);
    final showImage = autoLoad || _revealed;

    return Column(
      mainAxisSize: .min,
      spacing: 8,
      children: [
        Material(
          color: Colors.transparent,
          clipBehavior: Clip.hardEdge,
          shape: RoundedRectangleBorder(
            borderRadius: borderRadius,
            side: BorderSide(
              color: event.messageType == MessageTypes.Sticker
                  ? Colors.transparent
                  : theme.dividerColor,
            ),
          ),
          child: InkWell(
            onTap: showImage ? widget.onTap : _reveal,
            borderRadius: borderRadius,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Hero(
                  tag: event.eventId,
                  child: ConstrainedBox(
                    // Without known dimensions the image lays itself out at
                    // its own aspect ratio; cap it so a portrait photo is
                    // cropped instead of turning the message into a wall.
                    constraints: BoxConstraints(
                      maxWidth: width,
                      maxHeight: height ?? width * ImageBubble.maxAspectRatio,
                    ),
                    child: showImage
                        ? MxcImage(
                            event: event,
                            width: width,
                            height: height,
                            fit: fit,
                            animated: animated,
                            isThumbnail: thumbnailOnly,
                            // Share decoded bytes with the full-screen viewer's
                            // thumbnail placeholder so opening/closing doesn't
                            // flash black while the image re-decodes.
                            cacheKey: '${event.eventId}_thumb',
                            placeholder:
                                event.messageType == MessageTypes.Sticker
                                ? null
                                : (_) => _ImageBubblePlaceholder(
                                    event: event,
                                    width: width,
                                    height: height,
                                    fit: fit,
                                  ),
                          )
                        : _ImageBubblePlaceholder(
                            event: event,
                            width: width,
                            height: height,
                            fit: fit,
                            showDownloadHint: true,
                          ),
                  ),
                ),
                if (fileSendingStatus != null)
                  FileSendStatusIndicator(fileSendingStatus: fileSendingStatus),
              ],
            ),
          ),
        ),
        if (fileDescription != null && textColor != null)
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
                  color: widget.linkColor,
                  fontSize: AppConfig.messageFontSize,
                  decoration: TextDecoration.underline,
                  decorationColor: widget.linkColor,
                ),
                onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
              ),
            ),
          ),
      ],
    );
  }
}

class _ImageBubblePlaceholder extends StatelessWidget {
  final Event event;
  final double width;
  final double? height;
  final BoxFit fit;

  /// Overlay a download affordance, so a blurred bubble reads as "tap to load"
  /// rather than as an image that is still decoding.
  final bool showDownloadHint;

  /// Assumed aspect ratio while the real dimensions are unknown, so the bubble
  /// does not start out as a square and then jump.
  static const double _fallbackAspectRatio = 4 / 3;

  const _ImageBubblePlaceholder({
    required this.event,
    required this.width,
    required this.height,
    required this.fit,
    this.showDownloadHint = false,
  });

  @override
  Widget build(BuildContext context) {
    final blurHashString =
        event.infoMap.tryGet<String>('xyz.amorgan.blurhash') ??
        'LEHV6nWB2yk8pyo0adR*.7kCMdnj';
    final height = this.height ?? width / _fallbackAspectRatio;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          BlurHash(
            blurhash: blurHashString,
            width: width,
            height: height,
            fit: fit,
          ),
          if (showDownloadHint)
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(AppConfig.borderRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_outlined,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      L10n.of(context).tapToDownload,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
