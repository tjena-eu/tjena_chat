// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-space setting: whether a space's chats also appear in the main chat list
/// (outside the space). Stores the set of space IDs whose children are HIDDEN
/// from the main list (default: not hidden, i.e. children show everywhere).
/// App-local, per device.
class SpaceChildVisibility {
  SpaceChildVisibility._();
  static final SpaceChildVisibility instance = SpaceChildVisibility._();

  static const _key = 'space_hide_children_outside';

  final ValueNotifier<Set<String>> notifier = ValueNotifier<Set<String>>({});
  Set<String> get ids => notifier.value;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key);
      if (raw != null) notifier.value = raw.toSet();
    } catch (_) {}
  }

  /// True if this space's chats should NOT show in the main list.
  bool isHiddenOutside(String spaceId) => ids.contains(spaceId);

  Future<void> setHiddenOutside(String spaceId, bool hidden) async {
    if (hidden == ids.contains(spaceId)) return;
    notifier.value = hidden
        ? {...ids, spaceId}
        : ids.where((id) => id != spaceId).toSet();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, ids.toList());
    } catch (_) {}
  }
}
