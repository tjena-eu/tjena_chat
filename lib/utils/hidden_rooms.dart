// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-local registry of hidden rooms. Hidden rooms (Matrix or WhatsApp) are
/// kept out of the chat list even when new messages arrive, until unhidden.
/// Stored locally (per device) in SharedPreferences.
class HiddenRooms {
  HiddenRooms._();
  static final HiddenRooms instance = HiddenRooms._();

  static const _key = 'hidden_rooms';

  /// Notifies listeners (e.g. the chat list) whenever the hidden set changes.
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

  bool isHidden(String roomId) => ids.contains(roomId);

  Future<void> hide(String roomId) async {
    if (ids.contains(roomId)) return;
    notifier.value = {...ids, roomId};
    await _save();
  }

  Future<void> unhide(String roomId) async {
    if (!ids.contains(roomId)) return;
    notifier.value = ids.where((id) => id != roomId).toSet();
    await _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, ids.toList());
    } catch (_) {}
  }
}
