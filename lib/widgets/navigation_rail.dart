// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/navi_rail_item.dart';
import 'package:fluffychat/pages/chat_list/start_chat_fab.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/stream_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _SpacesSortMode { nameAsc, nameDesc, dateDesc, dateAsc }

class SpacesNavigationRail extends StatefulWidget {
  final String? activeSpaceId;
  final void Function() onGoToChats;
  final void Function(String) onGoToSpaceId;

  const SpacesNavigationRail({
    required this.activeSpaceId,
    required this.onGoToChats,
    required this.onGoToSpaceId,
    super.key,
  });

  @override
  State<SpacesNavigationRail> createState() => _SpacesNavigationRailState();
}

class _SpacesNavigationRailState extends State<SpacesNavigationRail> {
  _SpacesSortMode _sortMode = _SpacesSortMode.dateDesc;
  Set<String> _pins = {};

  static const _sortPrefKey = 'spaces_sort_mode';
  static const _pinsPrefKey = 'pinned_spaces';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_sortPrefKey) ?? 0;
    final pins = prefs.getStringList(_pinsPrefKey) ?? [];
    if (!mounted) return;
    setState(() {
      _sortMode = _SpacesSortMode.values[modeIndex.clamp(0, _SpacesSortMode.values.length - 1)];
      _pins = pins.toSet();
    });
  }

  Future<void> _setSortMode(_SpacesSortMode mode) async {
    setState(() => _sortMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_sortPrefKey, mode.index);
  }

  Future<void> _togglePin(String spaceId) async {
    final newPins = Set<String>.from(_pins);
    if (newPins.contains(spaceId)) {
      newPins.remove(spaceId);
    } else {
      newPins.add(spaceId);
    }
    setState(() => _pins = newPins);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pinsPrefKey, newPins.toList());
  }

  List<Room> _sortSpaces(List<Room> spaces) {
    DateTime ts(Room r) => r.lastEvent?.originServerTs ?? DateTime(0);
    String name(Room r) => r.getLocalizedDisplayname().toLowerCase();

    int compare(Room a, Room b) => switch (_sortMode) {
      _SpacesSortMode.dateDesc => ts(b).compareTo(ts(a)),
      _SpacesSortMode.dateAsc  => ts(a).compareTo(ts(b)),
      _SpacesSortMode.nameAsc  => name(a).compareTo(name(b)),
      _SpacesSortMode.nameDesc => name(b).compareTo(name(a)),
    };

    final pinned   = spaces.where((s) => _pins.contains(s.id)).toList()..sort(compare);
    final unpinned = spaces.where((s) => !_pins.contains(s.id)).toList()..sort(compare);
    return [...pinned, ...unpinned];
  }

  void _showSortSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Sort spaces',
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
            ),
            for (final entry in {
              _SpacesSortMode.dateDesc: 'Newest activity first',
              _SpacesSortMode.dateAsc:  'Oldest activity first',
              _SpacesSortMode.nameAsc:  'Name A → Z',
              _SpacesSortMode.nameDesc: 'Name Z → A',
            }.entries)
              ListTile(
                leading: Icon(_sortIcon(entry.key)),
                title: Text(entry.value),
                trailing: _sortMode == entry.key ? const Icon(Icons.check) : null,
                onTap: () { Navigator.pop(ctx); _setSortMode(entry.key); },
              ),
          ],
        ),
      ),
    );
  }

  IconData _sortIcon(_SpacesSortMode mode) => switch (mode) {
    _SpacesSortMode.dateDesc => Icons.arrow_downward_outlined,
    _SpacesSortMode.dateAsc  => Icons.arrow_upward_outlined,
    _SpacesSortMode.nameAsc  => Icons.sort_by_alpha_outlined,
    _SpacesSortMode.nameDesc => Icons.sort_by_alpha_outlined,
  };

  void _showSpaceMenu(BuildContext context, Room space) {
    final displayname = space.getLocalizedDisplayname();
    final isPinned = _pins.contains(space.id);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                displayname,
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
            ),
            ListTile(
              leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(isPinned ? 'Unpin space' : 'Pin space'),
              onTap: () { Navigator.pop(ctx); _togglePin(space.id); },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final coloredMode = !FluffyThemes.isColumnMode(context);
    final theme = Theme.of(context);
    return Material(
      color: coloredMode ? theme.colorScheme.surfaceContainer : null,
      child: SafeArea(
        child: StreamBuilder(
          key: ValueKey(client.userID.toString()),
          stream: client.onSync.stream
              .where((s) => s.hasRoomUpdate)
              .rateLimit(const Duration(seconds: 1)),
          builder: (context, _) {
            final allSpaces = _sortSpaces(
              client.rooms.where((room) => room.isSpace).toList(),
            );

            return SizedBox(
              width: FluffyThemes.isColumnMode(context)
                  ? FluffyThemes.navRailWidth
                  : FluffyThemes.navRailWidth * 0.75,
              child: Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.vertical,
                      itemCount: allSpaces.length + 2,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return NaviRailItem(
                            isSelected: widget.activeSpaceId == null,
                            onTap: widget.onGoToChats,
                            icon: const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Icon(Icons.forum_outlined),
                            ),
                            selectedIcon: const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Icon(Icons.forum),
                            ),
                            toolTip: L10n.of(context).chats,
                            unreadBadgeFilter: (room) => true,
                          );
                        }
                        i--;
                        if (i == allSpaces.length) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              NaviRailItem(
                                isSelected: false,
                                onTap: () => context.go('/rooms/newspace'),
                                icon: const Padding(
                                  padding: EdgeInsets.all(6.0),
                                  child: Icon(Icons.add),
                                ),
                                toolTip: L10n.of(context).createNewSpace,
                              ),
                              NaviRailItem(
                                isSelected: false,
                                onTap: () => _showSortSheet(context),
                                icon: Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Icon(
                                    _sortIcon(_sortMode),
                                    size: 20,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                toolTip: 'Sort spaces',
                              ),
                            ],
                          );
                        }
                        final space = allSpaces[i];
                        final displayname = allSpaces[i]
                            .getLocalizedDisplayname(
                              MatrixLocals(L10n.of(context)),
                            );
                        final spaceChildrenIds = space.spaceChildren
                            .map((c) => c.roomId)
                            .toSet();
                        final isPinned = _pins.contains(space.id);
                        return NaviRailItem(
                          toolTip: isPinned ? '$displayname (pinned)' : displayname,
                          isSelected: widget.activeSpaceId == space.id,
                          onTap: () => widget.onGoToSpaceId(allSpaces[i].id),
                          onLongPress: () => _showSpaceMenu(context, space),
                          unreadBadgeFilter: (room) =>
                              spaceChildrenIds.contains(room.id),
                          icon: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Avatar(
                                mxContent: allSpaces[i].avatar,
                                name: displayname,
                                size: 36,
                                shapeBorder: RoundedSuperellipseBorder(
                                  side: BorderSide(
                                    width: 1,
                                    color: Theme.of(context).dividerColor,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppConfig.spaceBorderRadius,
                                  ),
                                ),
                                borderRadius: BorderRadius.circular(
                                  AppConfig.spaceBorderRadius,
                                ),
                              ),
                              if (isPinned)
                                Positioned(
                                  bottom: -2,
                                  right: -2,
                                  child: Container(
                                    padding: const EdgeInsets.all(1),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.push_pin,
                                      size: 8,
                                      color: theme.colorScheme.onPrimary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  if (FluffyThemes.isColumnMode(context))
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: StartChatFab(),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
