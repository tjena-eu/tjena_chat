// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/chat/events/video_player.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/client_stories_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Full-screen, auto-advancing viewer for one user's story (their MSC3588
/// stories room). Progress bars at the top, tap to skip, hold to pause.
class StoryViewer extends StatefulWidget {
  final Room room;

  const StoryViewer({required this.room, super.key});

  static Future<void> show(BuildContext context, Room room) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => StoryViewer(room: room),
          fullscreenDialog: true,
        ),
      );

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer>
    with SingleTickerProviderStateMixin {
  static const _imageDuration = Duration(seconds: 6);
  static const _videoDuration = Duration(seconds: 20);

  late final AnimationController _controller;
  Timeline? _timeline;
  List<Event> _posts = [];
  int _index = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _imageDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _next();
      });
    _load();
  }

  Future<void> _load() async {
    try {
      final timeline = await widget.room.getTimeline();
      final posts = widget.room.storyPosts(timeline);
      if (!mounted) return;
      if (posts.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _timeline = timeline;
        _posts = posts;
        _loading = false;
      });
      _startCurrent();
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Duration _durationFor(Event event) =>
      event.messageType == MessageTypes.Video ? _videoDuration : _imageDuration;

  void _startCurrent() {
    _controller
      ..stop()
      ..duration = _durationFor(_posts[_index])
      ..forward(from: 0);
  }

  void _next() {
    if (_index < _posts.length - 1) {
      setState(() => _index++);
      _startCurrent();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() => _index--);
    }
    _startCurrent();
  }

  @override
  void dispose() {
    _controller.dispose();
    _timeline?.cancelSubscriptions();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator.adaptive(),
        ),
      );
    }

    final event = _posts[_index];
    final author = widget.room.storyAuthorId ?? widget.room.name;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final width = MediaQuery.sizeOf(context).width;
          if (details.localPosition.dx < width / 3) {
            _previous();
          } else {
            _next();
          }
        },
        onLongPressStart: (_) => _controller.stop(),
        onLongPressEnd: (_) => _controller.forward(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: _StoryContent(event: event)),
            // Progress bars + header overlay.
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      children: List.generate(_posts.length, (i) {
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: AnimatedBuilder(
                              animation: _controller,
                              builder: (context, _) {
                                final value = i < _index
                                    ? 1.0
                                    : i == _index
                                    ? _controller.value
                                    : 0.0;
                                return LinearProgressIndicator(
                                  value: value,
                                  minHeight: 3,
                                  backgroundColor: Colors.white24,
                                  valueColor: const AlwaysStoppedAnimation(
                                    Colors.white,
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  ListTile(
                    leading: Avatar(
                      name: author,
                      client: Matrix.of(context).client,
                      size: 36,
                    ),
                    title: Text(
                      author,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      event.originServerTs.localizedTimeShort(context),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: Navigator.of(context).pop,
                    ),
                  ),
                ],
              ),
            ),
            // Optional caption / text for the current post.
            if (event.messageType == MessageTypes.Text ||
                (event.body.isNotEmpty &&
                    event.messageType != MessageTypes.Image &&
                    event.messageType != MessageTypes.Video))
              Positioned(
                left: 0,
                right: 0,
                bottom: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    event.body,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StoryContent extends StatelessWidget {
  final Event event;

  const _StoryContent({required this.event});

  @override
  Widget build(BuildContext context) {
    switch (event.messageType) {
      case MessageTypes.Image:
        return MxcImage(
          event: event,
          isThumbnail: false,
          fit: BoxFit.contain,
          width: MediaQuery.sizeOf(context).width,
          height: MediaQuery.sizeOf(context).height,
        );
      case MessageTypes.Video:
        return EventVideoPlayer(event);
      default:
        // Text-only stories: nothing in the centre (text is overlaid below).
        return const SizedBox.shrink();
    }
  }
}
