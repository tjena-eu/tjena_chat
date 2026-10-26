// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/image_viewer/image_viewer.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A small "media library" grid for a burst of images sent back-to-back by
/// the same sender, mirroring WhatsApp's grouped-photos preview so a dozen
/// photos don't turn into a dozen separate bubbles. Tapping any tile opens
/// the full-screen [ImageViewer], which already gallery-swipes across every
/// image in the timeline (including the rest of this group).
class MediaGridBubble extends StatelessWidget {
  final List<Event> events;
  final Timeline timeline;
  final BorderRadius borderRadius;

  /// At most this many tiles are shown; the rest are folded into a "+N"
  /// overlay on the last visible tile.
  static const int maxTiles = 6;
  static const double _spacing = 3;
  static const double _width = 240;

  const MediaGridBubble(
    this.events, {
    required this.timeline,
    required this.borderRadius,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tileCount = events.length > maxTiles ? maxTiles : events.length;
    final overflow = events.length - tileCount;
    final crossAxisCount = events.length <= 2 ? 2 : 3;
    final tileSize =
        (_width - _spacing * (crossAxisCount - 1)) / crossAxisCount;

    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox(
        width: _width,
        child: GridView.count(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: _spacing,
          crossAxisSpacing: _spacing,
          children: List.generate(tileCount, (i) {
            final event = events[i];
            final isLastVisible = overflow > 0 && i == tileCount - 1;
            return InkWell(
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
                  // animation from bubble to fullscreen.
                  transitionsBuilder: (_, _, _, child) => child,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: event.eventId,
                    child: MxcImage(
                      event: event,
                      width: tileSize,
                      height: tileSize,
                      fit: BoxFit.cover,
                      isThumbnail: true,
                      cacheKey: '${event.eventId}_thumb',
                    ),
                  ),
                  if (isLastVisible)
                    Container(
                      color: Colors.black.withAlpha(140),
                      alignment: Alignment.center,
                      child: Text(
                        '+${overflow + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}
