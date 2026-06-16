// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BackupSchedule {
  off,
  daily,
  weekly,
  monthly;

  String get label => switch (this) {
    BackupSchedule.off => 'Off',
    BackupSchedule.daily => 'Daily',
    BackupSchedule.weekly => 'Weekly',
    BackupSchedule.monthly => 'Monthly',
  };

  Duration? get interval => switch (this) {
    BackupSchedule.off => null,
    BackupSchedule.daily => const Duration(days: 1),
    BackupSchedule.weekly => const Duration(days: 7),
    BackupSchedule.monthly => const Duration(days: 30),
  };

  static BackupSchedule fromString(String? s) =>
      BackupSchedule.values.firstWhere(
        (e) => e.name == s,
        orElse: () => BackupSchedule.off,
      );
}

class LocalBackupService {
  static const _lastMsKey = 'local_backup_last_ms';
  static const _lastDateKey = 'local_backup_last_date';
  static const _scheduleKey = 'local_backup_schedule';
  static const _autoDirKey = 'local_backup_auto_dir';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static Future<BackupSchedule> getSchedule() async {
    final p = await _prefs;
    return BackupSchedule.fromString(p.getString(_scheduleKey));
  }

  static Future<void> setSchedule(BackupSchedule s) async {
    final p = await _prefs;
    await p.setString(_scheduleKey, s.name);
  }

  static Future<String?> getLastBackupDate() async {
    final p = await _prefs;
    return p.getString(_lastDateKey);
  }

  static Future<DateTime?> getLastBackupTime() async {
    final p = await _prefs;
    final ms = p.getInt(_lastMsKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<DateTime?> nextScheduledBackup() async {
    final schedule = await getSchedule();
    final interval = schedule.interval;
    if (interval == null) return null;
    final last = await getLastBackupTime();
    if (last == null) return DateTime.now();
    return last.add(interval);
  }

  static Future<bool> isDue() async {
    final next = await nextScheduledBackup();
    if (next == null) return false;
    return DateTime.now().isAfter(next);
  }

  /// Runs backup to [directory] (or default external dir if null).
  /// Returns the output file path, or null on failure.
  static Future<String?> runAutoBackup(Client client, {String? directory}) async {
    final dir = directory ?? await _defaultDir();
    if (dir == null) return null;

    final zipPath =
        '$dir/tjena_backup_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.zip';

    try {
      await _writeZip(client, zipPath);
      await _recordSuccess(zipPath);
      final p = await _prefs;
      await p.setString(_autoDirKey, dir);
      return zipPath;
    } catch (e) {
      Logs().e('[LocalBackup] Auto-backup failed: $e');
      return null;
    }
  }

  /// Checks if a scheduled backup is due and runs it. No-op if off or not due.
  static Future<void> runIfDue(Client client) async {
    if (!await isDue()) return;
    final p = await _prefs;
    final savedDir = p.getString(_autoDirKey);
    await runAutoBackup(client, directory: savedDir);
  }

  /// Writes all room timelines into a zip at [zipPath].
  static Future<void> writeZipTo(Client client, String zipPath) =>
      _writeZip(client, zipPath);

  static Future<void> recordSuccess(String path) => _recordSuccess(path);

  // ── private ──────────────────────────────────────────────────────────────

  static Future<String?> _defaultDir() async {
    try {
      final dir = await getExternalStorageDirectory();
      return dir?.path;
    } catch (_) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        return dir.path;
      } catch (_) {
        return null;
      }
    }
  }

  static Future<void> _writeZip(Client client, String zipPath) async {
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    try {
      for (final room in client.rooms) {
        final roomName = _sanitize(room.getLocalizedDisplayname());
        try {
          final timeline = await room.getTimeline();
          final events = timeline.events
              .where(
                (e) =>
                    e.type == EventTypes.Message ||
                    e.type == EventTypes.Sticker ||
                    e.type == EventTypes.Encrypted,
              )
              .toList();

          final messages = events
              .map(
                (e) => {
                  'id': e.eventId,
                  'sender': e.senderId,
                  'type': e.type,
                  'body': e.body,
                  'timestamp': e.originServerTs.toIso8601String(),
                  'message_type': e.messageType,
                  if (e.content['url'] is String) 'url': e.content['url'],
                },
              )
              .toList();

          final json = jsonEncode({
            'room_id': room.id,
            'room_name': room.getLocalizedDisplayname(),
            'exported_at': DateTime.now().toIso8601String(),
            'messages': messages,
          });
          final bytes = utf8.encode(json);
          encoder.addArchiveFile(ArchiveFile('$roomName.json', bytes.length, bytes));
          timeline.cancelSubscriptions();
        } catch (_) {}
      }
    } finally {
      encoder.close();
    }
  }

  static Future<void> _recordSuccess(String path) async {
    final now = DateTime.now();
    final p = await _prefs;
    await p.setInt(_lastMsKey, now.millisecondsSinceEpoch);
    await p.setString(_lastDateKey, DateFormat('yyyy-MM-dd HH:mm').format(now));
  }

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
}
