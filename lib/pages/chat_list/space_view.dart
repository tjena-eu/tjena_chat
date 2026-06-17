// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/unread_bubble.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/client_stories_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/stream_extension.dart';
import 'package:fluffychat/utils/string_color.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/hover_builder.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SpaceChildAction {
  mute,
  unmute,
  markAsUnread,
  markAsRead,
  removeFromSpace,
  leave,
  pin,
  unpin,
  archive,
  unarchive,
}

enum _SpaceSortMode { dateDesc, dateAsc, nameAsc, nameDesc }

enum SpaceActions { settings, invite, members, leave }

class SpaceView extends StatefulWidget {
  final String spaceId;
  final void Function() onBack;
  final void Function(Room room) onChatTab;
  final String? activeChat;

  const SpaceView({
    required this.spaceId,
    required this.onBack,
    required this.onChatTab,
    required this.activeChat,
    super.key,
  });

  @override
  State<SpaceView> createState() => _SpaceViewState();
}

class _SpaceViewState extends State<SpaceView> {
  final List<SpaceRoomsChunk$2> _discoveredChildren = [];
  final TextEditingController _filterController = TextEditingController();
  String? _nextBatch;
  bool _noMoreRooms = false;
  bool _isLoading = false;

  _SpaceSortMode _sortMode = _SpaceSortMode.dateDesc;
  Set<String> _pins = {};
  Set<String> _archived = {};
  bool _showArchived = false;

  String get _sortPrefKey => 'space_sort_mode_${widget.spaceId}';
  String get _pinsPrefKey => 'space_pins_${widget.spaceId}';
  String get _archivedPrefKey => 'space_archived_${widget.spaceId}';

  StreamSubscription? _childStateSub;

  @override
  void initState() {
    _loadPrefs();
    _loadHierarchy();
    _childStateSub = Matrix.of(context).client.onSync.stream
        .where(
          (syncUpdate) =>
              syncUpdate.rooms?.join?[widget.spaceId]?.timeline?.events?.any(
                (event) => event.type == EventTypes.SpaceChild,
              ) ??
              false,
        )
        // Always reset to page 1 on space-child changes so sort/pins stay correct.
        .listen((_) => _refreshHierarchy());
    super.initState();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_sortPrefKey) ?? 0;
    final pins = prefs.getStringList(_pinsPrefKey) ?? [];
    final archived = prefs.getStringList(_archivedPrefKey) ?? [];
    if (!mounted) return;
    setState(() {
      _sortMode = _SpaceSortMode.values[modeIndex.clamp(
        0,
        _SpaceSortMode.values.length - 1,
      )];
      _pins = pins.toSet();
      _archived = archived.toSet();
    });
  }

  Future<void> _setSortMode(_SpaceSortMode mode) async {
    setState(() => _sortMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_sortPrefKey, mode.index);
  }

  Future<void> _togglePin(String roomId) async {
    final newPins = Set<String>.from(_pins);
    if (newPins.contains(roomId)) {
      newPins.remove(roomId);
    } else {
      newPins.add(roomId);
    }
    setState(() => _pins = newPins);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pinsPrefKey, newPins.toList());
  }

  Future<void> _toggleArchive(String roomId) async {
    final newArchived = Set<String>.from(_archived);
    if (newArchived.contains(roomId)) {
      newArchived.remove(roomId);
    } else {
      newArchived.add(roomId);
    }
    setState(() => _archived = newArchived);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_archivedPrefKey, newArchived.toList());
  }

  List<SpaceRoomsChunk$2> _applySortAndPin(
    List<SpaceRoomsChunk$2> children,
    sdk.Client client,
  ) {
    DateTime ts(SpaceRoomsChunk$2 c) =>
        client.getRoomById(c.roomId)?.lastEvent?.originServerTs ?? DateTime(0);
    String name(SpaceRoomsChunk$2 c) =>
        (c.name ??
                c.canonicalAlias ??
                client.getRoomById(c.roomId)?.getLocalizedDisplayname() ??
                '')
            .toLowerCase();

    int compare(SpaceRoomsChunk$2 a, SpaceRoomsChunk$2 b) =>
        switch (_sortMode) {
          _SpaceSortMode.dateDesc => ts(b).compareTo(ts(a)),
          _SpaceSortMode.dateAsc => ts(a).compareTo(ts(b)),
          _SpaceSortMode.nameAsc => name(a).compareTo(name(b)),
          _SpaceSortMode.nameDesc => name(b).compareTo(name(a)),
        };

    final pinned =
        children.where((c) => _pins.contains(c.roomId)).toList()
          ..sort(compare);
    final unpinned =
        children.where((c) => !_pins.contains(c.roomId)).toList()
          ..sort(compare);
    return [...pinned, ...unpinned];
  }

  void _showSortMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('Newest first'),
              trailing: _sortMode == _SpaceSortMode.dateDesc
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _setSortMode(_SpaceSortMode.dateDesc);
              },
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('Oldest first'),
              trailing: _sortMode == _SpaceSortMode.dateAsc
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _setSortMode(_SpaceSortMode.dateAsc);
              },
            ),
            ListTile(
              leading: const Icon(Icons.sort_by_alpha_outlined),
              title: const Text('Name A → Z'),
              trailing: _sortMode == _SpaceSortMode.nameAsc
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _setSortMode(_SpaceSortMode.nameAsc);
              },
            ),
            ListTile(
              leading: const Icon(Icons.sort_by_alpha_outlined),
              title: const Text('Name Z → A'),
              trailing: _sortMode == _SpaceSortMode.nameDesc
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _setSortMode(_SpaceSortMode.nameDesc);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _childStateSub?.cancel();
    super.dispose();
  }

  /// Resets pagination and reloads from the first page. Called when space
  /// child state changes so sort/pins remain consistent across all pages.
  Future<void> _refreshHierarchy() async {
    _nextBatch = null;
    _noMoreRooms = false;
    _discoveredChildren.clear();
    await _loadHierarchy();
  }

  /// Loads the next page (or first page when [_nextBatch] is null).
  /// Deduplicates against already-loaded rooms so loading more never
  /// corrupts the list that sort and pins operate on.
  Future<void> _loadHierarchy() async {
    final matrix = Matrix.of(context);
    final room = matrix.client.getRoomById(widget.spaceId);
    if (room == null) return;

    final cacheKey = 'spaces_history_cache${room.id}';
    if (_discoveredChildren.isEmpty && _nextBatch == null) {
      final cachedChildren = matrix.store.getStringList(cacheKey);
      if (cachedChildren != null) {
        try {
          _discoveredChildren.addAll(
            cachedChildren.map(
              (jsonString) =>
                  SpaceRoomsChunk$2.fromJson(jsonDecode(jsonString)),
            ),
          );
        } catch (e, s) {
          Logs().e('Unable to json decode spaces hierarchy cache!', e, s);
          matrix.store.remove(cacheKey);
        }
      }
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final hierarchy = await room.client.getSpaceHierarchy(
        widget.spaceId,
        suggestedOnly: false,
        maxDepth: 2,
        from: _nextBatch,
      );
      if (!mounted) return;
      setState(() {
        _nextBatch = hierarchy.nextBatch;
        if (hierarchy.nextBatch == null) _noMoreRooms = true;

        // Deduplicate: rooms already in the list stay where they are
        // (preserving any in-memory order before sort is applied).
        final existingIds =
            _discoveredChildren.map((c) => c.roomId).toSet();
        _discoveredChildren.addAll(
          hierarchy.rooms.where(
            (r) => r.roomId != widget.spaceId && !existingIds.contains(r.roomId),
          ),
        );
        _isLoading = false;
      });

      // Cache only when we have a complete first-page load.
      if (_nextBatch == null) {
        matrix.store.setStringList(
          cacheKey,
          _discoveredChildren
              .map((child) => jsonEncode(child.toJson()))
              .toList(),
        );
      }
    } catch (e, s) {
      Logs().w('Unable to load hierarchy', e, s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toLocalizedString(context))),
      );
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _joinChildRoom(SpaceRoomsChunk$2 item) async {
    final client = Matrix.of(context).client;
    final space = client.getRoomById(widget.spaceId);
    final via = space?.spaceChildren
        .firstWhereOrNull((child) => child.roomId == item.roomId)
        ?.via;
    final roomResult = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final waitForRoom = client.waitForRoomInSync(item.roomId, join: true);
        await client.joinRoom(item.roomId, via: via);
        await waitForRoom;
        return client.getRoomById(item.roomId)!;
      },
    );
    final room = roomResult.result;
    if (room != null) widget.onChatTab(room);
  }

  Future<void> _onSpaceAction(SpaceActions action) async {
    final space = Matrix.of(context).client.getRoomById(widget.spaceId);

    switch (action) {
      case SpaceActions.settings:
        await space?.postLoad();
        if (!mounted) return;
        context.push('/rooms/${widget.spaceId}/details');
        break;
      case SpaceActions.invite:
        await space?.postLoad();
        if (!mounted) return;
        context.push('/rooms/${widget.spaceId}/invite');
        break;
      case SpaceActions.members:
        await space?.postLoad();
        if (!mounted) return;
        context.push('/rooms/${widget.spaceId}/details/members');
        break;
      case SpaceActions.leave:
        final confirmed = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).areYouSure,
          message: L10n.of(context).archiveRoomDescription,
          okLabel: L10n.of(context).leave,
          cancelLabel: L10n.of(context).cancel,
          isDestructive: true,
        );
        if (!mounted) return;
        if (confirmed != OkCancelResult.ok) return;

        final success = await showFutureLoadingDialog(
          context: context,
          future: () async => await space?.leave(),
        );
        if (!mounted) return;
        if (success.error != null) return;
        widget.onBack();
    }
  }

  Future<void> _showSpaceChildEditMenu(
    BuildContext posContext,
    String roomId,
  ) async {
    final client = Matrix.of(context).client;
    final space = client.getRoomById(widget.spaceId);
    final room = client.getRoomById(roomId);
    if (space == null) return;
    final overlay =
        Overlay.of(posContext).context.findRenderObject() as RenderBox;

    final button = posContext.findRenderObject() as RenderBox;

    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(const Offset(0, -65), ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + const Offset(-50, 0),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final isArchived = _archived.contains(roomId);
    final isPinned = _pins.contains(roomId);

    final action = await showMenu<SpaceChildAction>(
      context: posContext,
      position: position,
      items: [
        PopupMenuItem(
          value: isPinned ? SpaceChildAction.unpin : SpaceChildAction.pin,
          child: Row(
            mainAxisSize: .min,
            children: [
              Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
              const SizedBox(width: 12),
              Text(isPinned ? 'Unpin' : 'Pin'),
            ],
          ),
        ),
        PopupMenuItem(
          value:
              isArchived ? SpaceChildAction.unarchive : SpaceChildAction.archive,
          child: Row(
            mainAxisSize: .min,
            children: [
              Icon(
                isArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              const SizedBox(width: 12),
              Text(isArchived ? 'Unarchive' : 'Archive'),
            ],
          ),
        ),
        if (room != null && room.membership == Membership.join) ...[
          PopupMenuItem(
            value: room.pushRuleState == PushRuleState.notify
                ? SpaceChildAction.mute
                : SpaceChildAction.unmute,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  room.pushRuleState == PushRuleState.notify
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_on_outlined,
                ),
                const SizedBox(width: 12),
                Text(
                  room.pushRuleState == PushRuleState.notify
                      ? L10n.of(context).muteChat
                      : L10n.of(context).unmuteChat,
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: room.markedUnread
                ? SpaceChildAction.markAsRead
                : SpaceChildAction.markAsUnread,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  room.markedUnread
                      ? Icons.mark_as_unread
                      : Icons.mark_as_unread_outlined,
                ),
                const SizedBox(width: 12),
                Text(
                  room.isUnread
                      ? L10n.of(context).markAsRead
                      : L10n.of(context).markAsUnread,
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: SpaceChildAction.leave,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  Icons.delete_outlined,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Text(
                  L10n.of(context).leave,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (space.canChangeStateEvent(EventTypes.SpaceChild) == true)
          PopupMenuItem(
            value: SpaceChildAction.removeFromSpace,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  Icons.remove,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Text(
                  L10n.of(context).removeFromSpace,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (action == null) return;
    if (!mounted) return;
    switch (action) {
      case SpaceChildAction.removeFromSpace:
        final consent = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).removeFromSpace,
          message: L10n.of(context).removeFromSpaceDescription,
        );
        if (consent != OkCancelResult.ok) return;
        if (!mounted) return;
        final result = await showFutureLoadingDialog(
          context: context,
          future: () => space.removeSpaceChild(roomId),
        );
        if (result.isError) return;
        if (!mounted) return;
        await _refreshHierarchy();
        return;
      case SpaceChildAction.mute:
        await showFutureLoadingDialog(
          context: context,
          future: () => room!.setPushRuleState(PushRuleState.mentionsOnly),
        );
      case SpaceChildAction.unmute:
        await showFutureLoadingDialog(
          context: context,
          future: () => room!.setPushRuleState(PushRuleState.notify),
        );
      case SpaceChildAction.markAsUnread:
        await showFutureLoadingDialog(
          context: context,
          future: () => room!.markUnread(true),
        );
      case SpaceChildAction.markAsRead:
        await showFutureLoadingDialog(
          context: context,
          future: () => room!.markUnread(false),
        );
      case SpaceChildAction.leave:
        await showFutureLoadingDialog(
          context: context,
          future: () => room!.leave(),
        );
      case SpaceChildAction.pin:
      case SpaceChildAction.unpin:
        await _togglePin(roomId);
      case SpaceChildAction.archive:
      case SpaceChildAction.unarchive:
        await _toggleArchive(roomId);
    }
  }

  IconData get _sortModeIcon => switch (_sortMode) {
    _SpaceSortMode.dateDesc => Icons.arrow_downward_outlined,
    _SpaceSortMode.dateAsc => Icons.arrow_upward_outlined,
    _SpaceSortMode.nameAsc => Icons.sort_by_alpha_outlined,
    _SpaceSortMode.nameDesc => Icons.sort_by_alpha_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final room = Matrix.of(context).client.getRoomById(widget.spaceId);
    final displayname =
        room?.getLocalizedDisplayname() ?? L10n.of(context).nothingFound;
    const avatarSize = Avatar.defaultSize / 1.5;
    final isAdmin = room?.canChangeStateEvent(EventTypes.SpaceChild) == true;

    // Rooms that are archived but have unread messages still count.
    final archivedUnread = _archived
        .where(
          (id) =>
              room?.client.getRoomById(id)?.isUnread == true,
        )
        .length;

    return Scaffold(
      appBar: AppBar(
        leading:
            FluffyThemes.isColumnMode(context) ||
                AppSettings.displayNavigationRail.value
            ? null
            : Center(child: CloseButton(onPressed: widget.onBack)),
        automaticallyImplyLeading: false,
        titleSpacing:
            FluffyThemes.isColumnMode(context) ||
                AppSettings.displayNavigationRail.value
            ? null
            : 0,
        title: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Avatar(
            size: avatarSize,
            mxContent: room?.avatar,
            name: displayname,
            shapeBorder: RoundedSuperellipseBorder(
              side: BorderSide(width: 1, color: theme.dividerColor),
              borderRadius: BorderRadius.circular(AppConfig.spaceBorderRadius),
            ),
            borderRadius: BorderRadius.circular(AppConfig.spaceBorderRadius),
          ),
          title: Text(
            displayname,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_sortModeIcon),
            tooltip: 'Sort',
            onPressed: () => _showSortMenu(context),
          ),
          if (_archived.isNotEmpty)
            IconButton(
              icon: Badge(
                isLabelVisible: archivedUnread > 0,
                label: Text('$archivedUnread'),
                child: Icon(
                  _showArchived
                      ? Icons.inventory_2
                      : Icons.inventory_2_outlined,
                ),
              ),
              tooltip: _showArchived
                  ? 'Hide archived'
                  : 'Show archived (${_archived.length})',
              onPressed: () =>
                  setState(() => _showArchived = !_showArchived),
            ),
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.add_outlined),
              tooltip: L10n.of(context).addChatOrSubSpace,
              onPressed: () =>
                  context.go('/rooms/newgroup?space_id=${widget.spaceId}'),
            ),
          PopupMenuButton<SpaceActions>(
            useRootNavigator: true,
            onSelected: _onSpaceAction,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: SpaceActions.settings,
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.settings_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).settings),
                  ],
                ),
              ),
              PopupMenuItem(
                value: SpaceActions.invite,
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.person_add_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).invite),
                  ],
                ),
              ),
              PopupMenuItem(
                value: SpaceActions.members,
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.group_outlined),
                    const SizedBox(width: 12),
                    Text(
                      L10n.of(context).countParticipants(
                        room?.summary.mJoinedMemberCount ?? 1,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: SpaceActions.leave,
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.delete_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).leave),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: room == null
          ? const Center(child: Icon(Icons.search_outlined, size: 80))
          : StreamBuilder(
              stream: room.client.onSync.stream
                  .where((s) => s.hasRoomUpdate)
                  .rateLimit(const Duration(seconds: 1)),
              builder: (context, snapshot) {
                final filter = _filterController.text.trim().toLowerCase();
                final sortedChildren = _applySortAndPin(
                  _discoveredChildren,
                  room.client,
                );
                return CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      floating: true,
                      scrolledUnderElevation: 0,
                      backgroundColor: Colors.transparent,
                      automaticallyImplyLeading: false,
                      title: TextField(
                        controller: _filterController,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: theme.colorScheme.secondaryContainer,
                          border: OutlineInputBorder(
                            borderSide: BorderSide.none,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          contentPadding: EdgeInsets.zero,
                          hintText: L10n.of(context).search,
                          hintStyle: TextStyle(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.normal,
                          ),
                          floatingLabelBehavior: FloatingLabelBehavior.never,
                          prefixIcon: IconButton(
                            onPressed: () {},
                            icon: Icon(
                              Icons.search_outlined,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: sortedChildren.length + 1,
                      itemBuilder: (context, i) {
                        if (i == sortedChildren.length) {
                          if (_noMoreRooms) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12.0,
                              vertical: 2.0,
                            ),
                            child: TextButton(
                              onPressed: _isLoading ? null : _loadHierarchy,
                              child: _isLoading
                                  ? const CircularProgressIndicator.adaptive()
                                  : Text(L10n.of(context).loadMore),
                            ),
                          );
                        }
                        final item = sortedChildren[i];
                        final isArchived = _archived.contains(item.roomId);

                        // Hide archived rooms unless the user toggled them on.
                        if (isArchived && !_showArchived) {
                          return const SizedBox.shrink();
                        }

                        var joinedRoom = room.client.getRoomById(item.roomId);
                        // Stories space: only show rooms you're actually in.
                        final isStoriesSpace =
                            room.client.storiesSpaceId == widget.spaceId ||
                            (room.client.storiesSpaceAlias != null &&
                                room.canonicalAlias ==
                                    room.client.storiesSpaceAlias);
                        if (isStoriesSpace &&
                            joinedRoom?.membership != Membership.join) {
                          return const SizedBox.shrink();
                        }
                        final displayname =
                            item.name ??
                            item.canonicalAlias ??
                            joinedRoom?.getLocalizedDisplayname() ??
                            L10n.of(context).emptyChat;
                        final avatarUrl = item.avatarUrl ?? joinedRoom?.avatar;
                        if (!displayname.toLowerCase().contains(filter)) {
                          return const SizedBox.shrink();
                        }
                        if (joinedRoom?.membership == Membership.leave) {
                          joinedRoom = null;
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 1,
                          ),
                          child: Material(
                            borderRadius: BorderRadius.circular(
                              AppConfig.borderRadius,
                            ),
                            clipBehavior: Clip.hardEdge,
                            color: isArchived
                                ? theme.colorScheme.surfaceContainerLow
                                : joinedRoom != null &&
                                    widget.activeChat == joinedRoom.id
                                ? theme.colorScheme.secondaryContainer
                                : Colors.transparent,
                            child: HoverBuilder(
                              builder: (context, hovered) => ListTile(
                                visualDensity: const VisualDensity(
                                  vertical: -0.5,
                                ),
                                contentPadding: EdgeInsets.only(
                                  left: 8,
                                  right: joinedRoom == null ? 0 : 8,
                                ),
                                onTap: joinedRoom != null
                                    ? () => widget.onChatTab(joinedRoom!)
                                    : null,
                                onLongPress: joinedRoom != null
                                    ? () => _showSpaceChildEditMenu(
                                        context,
                                        item.roomId,
                                      )
                                    : null,
                                leading: hovered
                                    ? SizedBox.square(
                                        dimension: avatarSize,
                                        child: IconButton(
                                          splashRadius: avatarSize,
                                          iconSize: 14,
                                          style: IconButton.styleFrom(
                                            foregroundColor: theme
                                                .colorScheme
                                                .onTertiaryContainer,
                                            backgroundColor: theme
                                                .colorScheme
                                                .tertiaryContainer,
                                          ),
                                          onPressed:
                                              isAdmin || joinedRoom != null
                                              ? () => _showSpaceChildEditMenu(
                                                  context,
                                                  item.roomId,
                                                )
                                              : null,
                                          icon: const Icon(Icons.edit_outlined),
                                        ),
                                      )
                                    : Avatar(
                                        size: avatarSize,
                                        mxContent: avatarUrl,
                                        name: '#',
                                        backgroundColor:
                                            theme.colorScheme.surfaceContainer,
                                        textColor:
                                            item.name?.darkColor ??
                                            theme.colorScheme.onSurface,
                                        shapeBorder: item.roomType == 'm.space'
                                            ? RoundedSuperellipseBorder(
                                                side: BorderSide(
                                                  color: theme
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      AppConfig.borderRadius /
                                                          4,
                                                    ),
                                              )
                                            : null,
                                        borderRadius: item.roomType == 'm.space'
                                            ? BorderRadius.circular(
                                                AppConfig.borderRadius / 4,
                                              )
                                            : null,
                                      ),
                                title: Row(
                                  children: [
                                    if (_pins.contains(item.roomId))
                                      const Padding(
                                        padding: EdgeInsets.only(right: 4),
                                        child: Icon(Icons.push_pin, size: 14),
                                      ),
                                    if (isArchived)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 4,
                                        ),
                                        child: Icon(
                                          Icons.archive_outlined,
                                          size: 14,
                                          color: theme.colorScheme.outline,
                                        ),
                                      ),
                                    Expanded(
                                      child: Opacity(
                                        opacity: isArchived
                                            ? 0.6
                                            : joinedRoom == null
                                            ? 0.5
                                            : 1,
                                        child: Text(
                                          displayname,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    if (joinedRoom != null &&
                                        joinedRoom.pushRuleState !=
                                            PushRuleState.notify)
                                      const Padding(
                                        padding: EdgeInsets.only(left: 4.0),
                                        child: Icon(
                                          Icons.notifications_off_outlined,
                                          size: 16,
                                        ),
                                      ),
                                    if (joinedRoom != null)
                                      UnreadBubble(room: joinedRoom)
                                    else
                                      TextButton(
                                        onPressed: () =>
                                            _joinChildRoom(item),
                                        child: Text(L10n.of(context).join),
                                      ),
                                  ],
                                ),
                                subtitle: AppSettings.spaceRoomPreview.value &&
                                        joinedRoom != null
                                    ? Text(
                                        joinedRoom.lastEvent
                                                ?.calcLocalizedBodyFallback(
                                                  MatrixLocals(L10n.of(context)),
                                                  hideReply: true,
                                                  hideEdit: true,
                                                  plaintextBody: true,
                                                  removeMarkdown: true,
                                                ) ??
                                            L10n.of(context).noMessagesYet,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SliverPadding(padding: EdgeInsets.only(top: 32)),
                  ],
                );
              },
            ),
    );
  }
}
