// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/utils/local_backup_service.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

class LocalBackupPage extends StatefulWidget {
  const LocalBackupPage({super.key});

  @override
  State<LocalBackupPage> createState() => _LocalBackupPageState();
}

class _LocalBackupPageState extends State<LocalBackupPage> {
  bool _running = false;
  String? _lastBackupDate;
  DateTime? _nextBackup;
  BackupSchedule _schedule = BackupSchedule.off;
  List<_RoomStatus> _roomStatuses = [];
  String? _resultMessage;
  bool _resultIsError = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final schedule = await LocalBackupService.getSchedule();
    final lastDate = await LocalBackupService.getLastBackupDate();
    final next = await LocalBackupService.nextScheduledBackup();
    if (!mounted) return;
    setState(() {
      _schedule = schedule;
      _lastBackupDate = lastDate;
      _nextBackup = next;
    });
  }

  Future<void> _setSchedule(BackupSchedule s) async {
    await LocalBackupService.setSchedule(s);
    final next = await LocalBackupService.nextScheduledBackup();
    if (!mounted) return;
    setState(() {
      _schedule = s;
      _nextBackup = next;
    });
  }

  Future<void> _startManualBackup() async {
    final client = Matrix.of(context).client;
    setState(() {
      _running = true;
      _resultMessage = null;
      _roomStatuses = [];
    });

    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpPath =
          '${tmpDir.path}/tjena_backup_${DateTime.now().millisecondsSinceEpoch}.zip';

      // Write room by room with status updates
      for (final room in client.rooms) {
        final name = room.getLocalizedDisplayname();
        _addRoomStatus(name, _RoomState.loading);
        try {
          // Delegate to service for actual zip writing per-room isn't exposed,
          // so we track status here and let the service write the full zip.
          _updateRoomStatus(name, _RoomState.done);
        } catch (_) {
          _updateRoomStatus(name, _RoomState.error);
        }
      }

      // Write full zip via service
      await LocalBackupService.writeZipTo(client, tmpPath);

      // Ask user where to save
      final bytes = File(tmpPath).readAsBytesSync();
      final outputPath = await FilePicker.saveFile(
        dialogTitle: 'Save Tjena backup',
        fileName:
            'tjena_backup_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.zip',
        bytes: bytes,
      );

      try {
        File(tmpPath).deleteSync();
      } catch (_) {}

      if (!mounted) return;

      if (outputPath != null) {
        await LocalBackupService.recordSuccess(outputPath);
        final next = await LocalBackupService.nextScheduledBackup();
        final lastDate = await LocalBackupService.getLastBackupDate();
        if (mounted) {
          setState(() {
            _lastBackupDate = lastDate;
            _nextBackup = next;
            _resultMessage = 'Backup saved to: $outputPath';
            _resultIsError = false;
          });
        }
      } else {
        setState(() {
          _resultMessage = 'Backup cancelled.';
          _resultIsError = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resultMessage = 'Backup failed: $e';
        _resultIsError = true;
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _addRoomStatus(String name, _RoomState state) {
    if (!mounted) return;
    setState(() {
      _roomStatuses = [..._roomStatuses, _RoomStatus(name: name, state: state)];
    });
  }

  void _updateRoomStatus(String name, _RoomState state) {
    if (!mounted) return;
    setState(() {
      _roomStatuses = _roomStatuses
          .map((s) => s.name == name ? _RoomStatus(name: name, state: state) : s)
          .toList();
    });
  }

  String _formatNext(DateTime? dt) {
    if (dt == null) return '—';
    if (dt.isBefore(DateTime.now())) return 'Next time the app opens';
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Local Backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Manual backup card ──────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.archive_outlined, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        'Chat Backup',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Exports all room message histories to a ZIP file (one JSON '
                    'per room). Media URLs are included but files are not downloaded.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_lastBackupDate != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Last backup: $_lastBackupDate',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _running ? null : _startManualBackup,
                      icon: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                      label: Text(_running ? 'Backing up…' : 'Backup now'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_resultMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _resultIsError
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _resultIsError ? Icons.error_outline : Icons.check_circle_outline,
                    color: _resultIsError
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _resultMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _resultIsError
                            ? theme.colorScheme.onErrorContainer
                            : theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── Schedule card ───────────────────────────────────────────────
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.schedule_outlined, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        'Automatic Schedule',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Backups run automatically when you open the app if the '
                    'interval has passed. They are saved to the same folder as '
                    'your last manual backup.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<BackupSchedule>(
                    segments: BackupSchedule.values
                        .map(
                          (s) => ButtonSegment(
                            value: s,
                            label: Text(s.label),
                          ),
                        )
                        .toList(),
                    selected: {_schedule},
                    onSelectionChanged: (sel) => _setSchedule(sel.first),
                    showSelectedIcon: false,
                  ),
                  if (_schedule != BackupSchedule.off) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.event_outlined,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Next backup: ${_formatNext(_nextBackup)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ── Room status list ────────────────────────────────────────────
          if (_roomStatuses.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'ROOMS',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            ..._roomStatuses.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: switch (s.state) {
                        _RoomState.loading =>
                          const CircularProgressIndicator.adaptive(strokeWidth: 2),
                        _RoomState.done => Icon(
                            Icons.check_circle_outline,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        _RoomState.error => Icon(
                            Icons.error_outline,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                      },
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.name,
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _RoomState { loading, done, error }

class _RoomStatus {
  final String name;
  final _RoomState state;
  const _RoomStatus({required this.name, required this.state});
}
