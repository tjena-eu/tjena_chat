// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/poll.dart';
import 'package:fluffychat/pages/chat/events/video_player.dart';
import 'package:fluffychat/pages/image_viewer/image_viewer.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import '../../../config/app_config.dart';
import '../../../utils/event_checkbox_extension.dart';
import '../../../utils/platform_infos.dart';
import '../../../utils/url_launcher.dart';
import 'audio_player.dart';
import 'cute_events.dart';
import 'html_message.dart';
import 'image_bubble.dart';
import 'map_bubble.dart';
import 'message_download_content.dart';

/// Timeline media is sized to the message bubble rather than to the media's own
/// resolution, so a photo or video never leaves the message narrower than the
/// bubble around it.
const double _maxMediaWidth = 320.0;

/// Stickers keep their old behaviour: small, and sized to the sticker itself.
const double _maxStickerSize = 128.0;

/// The media width to use for a bubble laid out with [constraints].
double mediaWidth(BoxConstraints constraints) => min(
  constraints.maxWidth.isFinite
      ? constraints.maxWidth
      : FluffyThemes.columnWidth * 1.5,
  _maxMediaWidth,
);

/// The height for media of [w] x [h] pixels rendered at [width].
///
/// Extreme aspect ratios are clamped (and cropped via `BoxFit.cover`) so that
/// neither a panorama nor a portrait photo distorts the bubble. Returns `null`
/// when the sender did not report any dimensions — the media then lays itself
/// out at its own aspect ratio once decoded.
double? mediaHeight(double width, int? w, int? h) {
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  return (width * h / w).clamp(width * 0.5, width * 1.4);
}

/// Sticker box for a sticker of [w] x [h] pixels: the longer side capped at
/// [_maxStickerSize], aspect ratio preserved.
Size stickerSize(int? w, int? h) {
  if (w == null || h == null || w <= 0 || h <= 0) {
    return const Size(_maxStickerSize, _maxStickerSize);
  }
  return w > h
      ? Size(_maxStickerSize, max(32, _maxStickerSize * (h / w)))
      : Size(max(32, _maxStickerSize * (w / h)), _maxStickerSize);
}

class MessageContent extends StatelessWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;
  final void Function(Event)? onInfoTab;
  final BorderRadius borderRadius;
  final Timeline timeline;
  final bool selected;
  final Set<String> bigEmojis;

  const MessageContent(
    this.event, {
    this.onInfoTab,
    super.key,
    required this.timeline,
    required this.textColor,
    required this.linkColor,
    required this.borderRadius,
    required this.selected,
    required this.bigEmojis,
  });

  Future<void> _verifyOrRequestKey(BuildContext context) async {
    final l10n = L10n.of(context);
    if (event.content['can_request_session'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(event.calcLocalizedBodyFallback(MatrixLocals(l10n))),
        ),
      );
      return;
    }
    final client = Matrix.of(context).client;
    final state = await client.getCryptoIdentityState();
    if (!state.connected) {
      if (!context.mounted) return;
      final success = await context.push('/backup');
      if (success != true) return;
    }
    if (!context.mounted) return;
    event.requestKey();
    final sender = event.senderFromMemoryOrFallback;
    await showAdaptiveBottomSheet(
      context: context,
      builder: (context) => Scaffold(
        appBar: AppBar(
          leading: CloseButton(onPressed: Navigator.of(context).pop),
          title: Text(
            l10n.whyIsThisMessageEncrypted,
            style: const TextStyle(fontSize: 16),
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Avatar(
                  mxContent: sender.avatarUrl,
                  name: sender.calcDisplayname(),
                  presenceUserId: sender.stateKey,
                  client: event.room.client,
                ),
                title: Text(sender.calcDisplayname()),
                subtitle: Text(event.originServerTs.localizedTime(context)),
                trailing: const Icon(Icons.lock_outlined),
              ),
              const Divider(),
              Text(event.calcLocalizedBodyFallback(MatrixLocals(l10n))),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const fontSize = AppConfig.messageFontSize;
    final buttonTextColor = textColor;
    switch (event.type) {
      case EventTypes.Message:
      case EventTypes.Encrypted:
      case EventTypes.Sticker:
        switch (event.messageType) {
          case MessageTypes.Image:
          case MessageTypes.Sticker:
            if (event.redacted) continue textmessage;
            final isSticker = event.messageType == MessageTypes.Sticker;
            final info = event.content.tryGetMap<String, Object?>('info');
            final w = info?.tryGet<int>('w');
            final h = info?.tryGet<int>('h');
            // Fill the bubble instead of sizing the bubble to the image: a
            // portrait photo used to shrink the whole message to a thin
            // sliver.
            return LayoutBuilder(
              builder: (context, constraints) {
                final double width;
                final double? height;
                if (isSticker) {
                  final size = stickerSize(w, h);
                  width = size.width;
                  height = size.height;
                } else {
                  width = mediaWidth(constraints);
                  height = mediaHeight(width, w, h);
                }
                return ImageBubble(
                  event,
                  width: width,
                  height: height,
                  fit: isSticker ? BoxFit.contain : BoxFit.cover,
                  borderRadius: borderRadius,
                  timeline: timeline,
                  textColor: textColor,
                  onTap: () => Navigator.of(context).push(
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
                  ),
                );
              },
            );
          case CuteEventContent.eventType:
            return CuteContent(event);
          case MessageTypes.Audio:
            if (PlatformInfos.isMobile ||
                PlatformInfos.isMacOS ||
                PlatformInfos.isWeb
            // Disabled until https://github.com/bleonard252/just_audio_mpv/issues/3
            // is fixed
            //   || PlatformInfos.isLinux
            ) {
              return AudioPlayerWidget(
                event,
                color: textColor,
                linkColor: linkColor,
                fontSize: fontSize,
              );
            }
            return MessageDownloadContent(
              event,
              textColor: textColor,
              linkColor: linkColor,
            );
          case MessageTypes.Video:
            return LayoutBuilder(
              builder: (context, constraints) => EventVideoPlayer(
                event,
                textColor: textColor,
                linkColor: linkColor,
                timeline: timeline,
                maxWidth: mediaWidth(constraints),
              ),
            );
          case MessageTypes.File:
            return MessageDownloadContent(
              event,
              textColor: textColor,
              linkColor: linkColor,
            );
          case MessageTypes.BadEncrypted:
          case EventTypes.Encrypted:
            return _ButtonContent(
              textColor: buttonTextColor,
              onPressed: () => _verifyOrRequestKey(context),
              icon: '🔒',
              label: L10n.of(context).encrypted,
              fontSize: fontSize,
            );
          case MessageTypes.Location:
            final geoUri = Uri.tryParse(
              event.content.tryGet<String>('geo_uri')!,
            );
            if (geoUri != null && geoUri.scheme == 'geo') {
              final latlong = geoUri.path
                  .split(';')
                  .first
                  .split(',')
                  .map(double.tryParse)
                  .toList();
              if (latlong.length == 2 &&
                  latlong.first != null &&
                  latlong.last != null) {
                return Column(
                  mainAxisSize: .min,
                  children: [
                    MapBubble(
                      latitude: latlong.first!,
                      longitude: latlong.last!,
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      icon: Icon(Icons.location_on_outlined, color: textColor),
                      onPressed: UrlLauncher(
                        context,
                        geoUri.toString(),
                      ).launchUrl,
                      label: Text(
                        L10n.of(context).openInMaps,
                        style: TextStyle(color: textColor),
                      ),
                    ),
                  ],
                );
              }
            }
            continue textmessage;
          case MessageTypes.Text:
          case MessageTypes.Notice:
          case MessageTypes.Emote:
          case MessageTypes.None:
          textmessage:
          default:
            if (event.redacted) {
              return RedactionWidget(
                event: event,
                buttonTextColor: buttonTextColor,
                onInfoTab: onInfoTab,
                fontSize: fontSize,
              );
            }
            var html = AppSettings.renderHtml.value && event.isRichMessage
                ? event.formattedText
                : event.body.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
            if (event.messageType == MessageTypes.Emote) {
              html = '* $html';
            }

            final bigEmotes =
                !event.isRichMessage && bigEmojis.contains(event.body);

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: HtmlMessage(
                html: html,
                textColor: textColor,
                room: event.room,
                fontSize: AppConfig.messageFontSize * (bigEmotes ? 5 : 1),
                linkStyle: TextStyle(
                  color: linkColor,
                  fontSize: AppConfig.messageFontSize,
                  decoration: TextDecoration.underline,
                  decorationColor: linkColor,
                ),
                onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
                eventId: event.eventId,
                checkboxCheckedEvents: event.aggregatedEvents(
                  timeline,
                  EventCheckboxRoomExtension.relationshipType,
                ),
              ),
            );
        }
      case PollEventContent.startType:
        if (event.redacted) {
          return RedactionWidget(
            event: event,
            buttonTextColor: buttonTextColor,
            onInfoTab: onInfoTab,
            fontSize: fontSize,
          );
        }
        return PollWidget(
          event: event,
          timeline: timeline,
          textColor: textColor,
          linkColor: linkColor,
        );
      case EventTypes.CallInvite:
        return FutureBuilder<User?>(
          future: event.fetchSenderUser(),
          builder: (context, snapshot) {
            return _ButtonContent(
              label: L10n.of(context).startedACall(
                snapshot.data?.calcDisplayname() ??
                    event.senderFromMemoryOrFallback.calcDisplayname(),
              ),
              icon: '📞',
              textColor: buttonTextColor,
              onPressed: () => onInfoTab!(event),
              fontSize: fontSize,
            );
          },
        );
      default:
        return FutureBuilder<User?>(
          future: event.fetchSenderUser(),
          builder: (context, snapshot) {
            return _ButtonContent(
              label: L10n.of(context).userSentUnknownEvent(
                snapshot.data?.calcDisplayname() ??
                    event.senderFromMemoryOrFallback.calcDisplayname(),
                event.type,
              ),
              icon: 'ℹ️',
              textColor: buttonTextColor,
              onPressed: () => onInfoTab!(event),
              fontSize: fontSize,
            );
          },
        );
    }
  }
}

class RedactionWidget extends StatelessWidget {
  const RedactionWidget({
    super.key,
    required this.event,
    required this.buttonTextColor,
    required this.onInfoTab,
    required this.fontSize,
  });

  final Event event;
  final Color buttonTextColor;
  final void Function(Event p1)? onInfoTab;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<User?>(
      future: event.redactedBecause?.fetchSenderUser(),
      builder: (context, snapshot) {
        final reason = event.redactedBecause?.content.tryGet<String>('reason');
        final redactedBy =
            snapshot.data?.calcDisplayname() ??
            event.redactedBecause?.senderId.localpart ??
            L10n.of(context).user;
        return _ButtonContent(
          label: reason == null
              ? L10n.of(context).redactedBy(redactedBy)
              : L10n.of(context).redactedByBecause(redactedBy, reason),
          icon: '🗑️',
          textColor: buttonTextColor.withAlpha(128),
          onPressed: () => onInfoTab!(event),
          fontSize: fontSize,
        );
      },
    );
  }
}

class _ButtonContent extends StatelessWidget {
  final void Function() onPressed;
  final String label;
  final String icon;
  final Color? textColor;
  final double fontSize;

  const _ButtonContent({
    required this.label,
    required this.icon,
    required this.textColor,
    required this.onPressed,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onPressed,
        child: Text(
          '$icon  $label',
          style: TextStyle(color: textColor, fontSize: fontSize),
        ),
      ),
    );
  }
}
