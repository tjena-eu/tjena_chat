import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native.dart';
import 'widgets.dart';

/// Progress and diagnostics of the WhatsApp history import: what the phone
/// sent, which chats got a room, how many messages were copied, and which
/// chats stopped early (and why). Reads the bridge's database and log; it
/// changes nothing.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  Map<String, dynamic>? _info;
  String? _error;
  Timer? _timer;
  bool _onlyProblems = false;
  bool _loading = false;
  bool _catchingUp = false;
  Map<String, dynamic> _pace = {};
  String _appVersion = '';
  Map<String, dynamic> _dp = {};

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_running) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final info = await Native.historyInfo();
      Map<String, dynamic> pace = {};
      var appVersion = '';
      try {
        final st = await Native.state();
        pace = st.pace;
        appVersion = st.appVersion;
      } catch (_) {}
      Map<String, dynamic> dp = {};
      try {
        dp = await Native.doublePuppet('status');
      } catch (_) {}
      if (mounted) {
        setState(() {
          _dp = dp;
          _info = info;
          _pace = pace;
          _appVersion = appVersion;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PlatformException ? (e.message ?? '$e') : '$e',
        );
      }
    } finally {
      _loading = false;
    }
  }

  Map<String, dynamic> get _log =>
      (_info?['log'] as Map?)?.cast<String, dynamic>() ?? {};
  List<Map<String, dynamic>> get _logins => ((_info?['logins'] as List?) ?? [])
      .cast<Map>()
      .map((m) => m.cast<String, dynamic>())
      .toList();

  int _sum(String k) =>
      _logins.fold(0, (a, l) => a + ((l[k] as num?)?.toInt() ?? 0));

  /// Why the screen thinks the import still runs (null = finished).
  String? get _runningWhy {
    if (_info == null) return null;
    final waiting = (_pace['sends_waiting'] as num?)?.toInt() ?? 0;
    if (waiting > 0) return '$waiting messages are still being sent';
    final pending = _sum('pending_chunks');
    if (pending > 0) {
      return '$pending history pieces from your phone not read yet';
    }
    if (_logins.any((l) => l['rooms_pending'] == true)) {
      return 'the bridge has not finished creating chats from history';
    }
    final log = _log;
    if (log['rooms_creating'] == true && log['rooms_done'] != true) {
      return 'chats are still being created';
    }
    return null;
  }

  bool get _running {
    if (_info == null) return true;
    if (((_pace['sends_waiting'] as num?) ?? 0) > 0) return true;
    final log = _log;
    if (_sum('pending_chunks') > 0) return true;
    if (_logins.any((l) => l['rooms_pending'] == true)) return true;
    return log['rooms_creating'] == true && log['rooms_done'] != true;
  }

  Future<void> _resumeDP() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Native.doublePuppet('resume');
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Double puppeting is on again. The bridge restarted.'),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
    _load();
  }

  Future<void> _catchup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Copy missing messages?'),
        content: const Text(
          'The bridge restarts and copies the stored messages that are missing at the end of the '
          'chats listed here. Your own messages go at the speed tjena allows, so this can take a while; '
          'keep the bridge running.\n\n'
          'Messages can only be added after the newest message already in a chat. If someone wrote '
          'in a chat after the import stopped, the gap before that message stays.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _catchingUp = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await Native.historyCatchup();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            (r['chats'] as num? ?? 0) == 0
                ? 'Nothing to copy.'
                : 'Copying ${r['stored']} messages in ${r['chats']} chats. This screen shows the progress.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed: ${e is PlatformException ? e.message : e}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _catchingUp = false);
      await Future.delayed(const Duration(seconds: 3));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _appVersion.isEmpty
              ? 'History import'
              : 'History import · v$_appVersion',
        ),
        actions: [
          IconButton(
            tooltip: 'Copy summary',
            onPressed: _info == null ? null : _copy,
            icon: const Icon(Icons.copy),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _info == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: ErrorText(
                        'Could not read the import state: $_error',
                      ),
                    )
                  : const CircularProgressIndicator(),
            )
          : RefreshIndicator(onRefresh: _load, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final t = Theme.of(context);
    final log = _log;
    final progress = (log['progress'] as Map?)?.cast<String, dynamic>() ?? {};
    final chunks = ((log['chunks'] as List?) ?? []).cast<Map>();
    final lastChunk = chunks.isEmpty
        ? null
        : chunks.last.cast<String, dynamic>();
    final lastChunkTime = DateTime.tryParse(
      lastChunk?['time'] as String? ?? '',
    );
    final phonePct = [
      for (final v in progress.values) (v as num).toInt(),
    ].fold<int>(0, (a, b) => b > a ? b : a);
    final pending = _sum('pending_chunks');
    final roomsTarget = (log['rooms_target'] as num?)?.toInt() ?? 0;
    final rooms = _sum('rooms');
    final roomsDone = log['rooms_done'] == true;
    final creating = log['rooms_creating'] == true;
    final copiedChats = (log['backfill_chats'] as num?)?.toInt() ?? 0;
    final notCopied = _sum('not_copied');
    final failedChats = _logins
        .expand((l) => (l['chats'] as List).cast<Map>())
        .where(
          (c) =>
              c['failed'] == true ||
              (c['has_room'] == true && ((c['stored'] as num?) ?? 0) > 0),
        )
        .length;
    final rateLimited = (log['rate_limited'] as num?)?.toInt() ?? 0;
    final errors = ((log['recent_errors'] as List?) ?? []).cast<Map>();
    final waiting = (_pace['sends_waiting'] as num?)?.toInt() ?? 0;
    final paceHits = (_pace['rate_limit_hits'] as num?)?.toInt() ?? 0;

    // Phase 1: the phone sends history; phase 2: rooms are created and filled.
    final phoneDone =
        creating ||
        roomsDone ||
        (phonePct >= 100 && pending == 0) ||
        (lastChunk == null && _sum('conversations') > 0 && pending == 0);
    String phoneText;
    if (lastChunk == null && _sum('conversations') > 0) {
      phoneText =
          'Received earlier: history for ${_sum('conversations')} chats '
          '(details are no longer in the log)'
          '${pending > 0 ? ' · $pending waiting to be read' : ''}';
    } else if (lastChunk == null) {
      phoneText = log['found'] == true
          ? 'Nothing received yet. Keep WhatsApp open on your phone.'
          : 'No bridge log found yet.';
    } else {
      final since = lastChunkTime == null
          ? ''
          : ' · last piece ${_ago(lastChunkTime)}';
      phoneText =
          '${chunks.length} pieces received, ${log['saved'] ?? 0} messages stored$since'
          '${pending > 0 ? ' · $pending waiting to be read' : ''}';
    }
    String roomsText;
    if (!creating) {
      roomsText = phoneDone
          ? 'Starting…'
          : 'Starts 5 minutes after the last piece from your phone (10 with "Lots").';
    } else {
      roomsText =
          '$rooms of $roomsTarget chats created · $copiedChats filled'
          '${roomsDone ? '' : ' · working…'}';
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Phase(
                    title: '1. History from your phone',
                    text: phoneText,
                    value: phoneDone
                        ? 1
                        : (phonePct > 0 ? phonePct / 100 : null),
                    done: phoneDone,
                    active: lastChunk != null || !phoneDone,
                  ),
                  const SizedBox(height: 16),
                  _Phase(
                    title: '2. Chats created and filled',
                    text: roomsText,
                    value: !creating
                        ? 0
                        : (roomsDone
                              ? 1
                              : (roomsTarget == 0
                                    ? null
                                    : rooms / roomsTarget)),
                    done: roomsDone,
                    active: creating,
                  ),
                  if (!_running && creating) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Import finished.',
                      style: t.textTheme.titleSmall?.copyWith(
                        color: Colors.green,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (_dp['paused'] == true)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    leading: Icon(Icons.bolt, color: t.colorScheme.primary),
                    title: const Text('Fast import: double puppeting paused'),
                    subtitle: Text(
                      'Your own messages are sent as "you on WhatsApp" for now, so tjena\'s speed limit '
                      'doesn\'t slow the import down. Double puppeting comes back by itself when the import '
                      'is done (at the latest 4 hours after it started)'
                      '${_dp['pending'] != null ? '. Now: ${_dp['pending']}.' : '.'}',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: TextButton(
                      onPressed: _resumeDP,
                      child: const Text('Turn double puppeting back on now'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (waiting > 0 || paceHits > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Card(
              child: ListTile(
                leading: Icon(
                  waiting > 0 ? Icons.hourglass_top : Icons.speed,
                  color: t.colorScheme.primary,
                ),
                title: Text(
                  waiting > 0
                      ? 'Sending slowly: $waiting messages waiting'
                      : 'Sending is paced to tjena\'s limit',
                ),
                subtitle: Text(
                  'tjena allows your own messages only at a certain speed. The bridge app waits and retries '
                  'instead of skipping them (limit reached $paceHits times, '
                  '${_pace['rate_limit_retried'] ?? 0} retried here, '
                  '${_pace['rate_limit_handed_back'] ?? 0} sent back to the bridge to retry later).',
                ),
              ),
            ),
          ),
        if (failedChats > 0 || notCopied > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: WarningCard(
              title:
                  '$failedChats chats stopped early · $notCopied messages not copied',
              text: rateLimited > 0
                  ? 'tjena refused messages for sending too fast ($rateLimited times), and the bridge skipped '
                        'the rest of those chats. The messages are still stored on this phone. '
                        '"Copy missing messages" restarts the bridge and copies them, slowly, at the speed tjena allows.'
                  : 'Copying stopped with an error in these chats; the rest of their history was skipped. '
                        'See "Errors" below. "Copy missing messages" tries these chats again.',
            ),
          ),
        if (failedChats > 0 || notCopied > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '${_sum('fillable')} of $notCopied can still be added at the end of their chats. '
              '${_sum('blocked_chats')} chats got newer messages after the import stopped, so their '
              'missing messages would land before those and can\'t be added any more.',
              style: t.textTheme.bodyMedium,
            ),
          ),
        if (failedChats > 0 || notCopied > 0) ...[
          if (_runningWhy != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Import may still be running: $_runningWhy. You can wait, or start copying now '
                '(the bridge restarts and continues from where it is).',
                style: t.textTheme.bodySmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: FilledButton.icon(
              onPressed: _catchingUp ? null : _catchup,
              icon: _catchingUp
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.replay),
              label: const Text('Copy missing messages'),
            ),
          ),
        ],
        const SectionTitle('Numbers'),
        _Num('Messages stored from your phone', '${log['saved'] ?? 0}'),
        _Num('Messages copied into chats', '${_sum('bridged_messages')}'),
        _Num(
          'Not copied (chat already created)',
          '$notCopied',
          bad: notCopied > 0,
        ),
        _Num(
          'Waiting for a chat (not in the first chats)',
          '${_sum('stored_messages') - notCopied}',
        ),
        _Num(
          'Skipped message types (calls, system notices…)',
          '${log['ignored'] ?? 0}',
        ),
        _Num(
          'Unreadable messages',
          '${log['parse_dropped'] ?? 0}',
          bad: ((log['parse_dropped'] as num?) ?? 0) > 0,
        ),
        _Num(
          'Rate-limit refusals from tjena',
          '$rateLimited',
          bad: rateLimited > 0,
        ),
        _Num(
          'Messages that failed to send',
          '${log['send_failed'] ?? 0}',
          bad: ((log['send_failed'] as num?) ?? 0) > 0,
        ),
        for (final e in progress.entries)
          _Num('Phone progress (${_typeName(e.key)})', '${e.value}%'),
        const SectionTitle('Chats'),
        SwitchListTile(
          dense: true,
          title: const Text('Only chats with problems'),
          value: _onlyProblems,
          onChanged: (v) => setState(() => _onlyProblems = v),
        ),
        for (final l in _logins) ..._chatTiles(context, l),
        if (errors.isNotEmpty) ...[
          const SectionTitle('Errors'),
          for (final e in errors.reversed.take(20))
            ListTile(
              dense: true,
              leading: Icon(
                Icons.error_outline,
                color: t.colorScheme.error,
                size: 18,
              ),
              title: Text('${e['msg']}'),
              subtitle: Text(
                [
                  _time(e['time'] as String?),
                  if ((e['chat'] as String?)?.isNotEmpty == true)
                    _short(e['chat'] as String),
                  if ((e['error'] as String?)?.isNotEmpty == true) e['error'],
                ].join(' · '),
              ),
            ),
        ],
        for (final err in ((_info?['errors'] as List?) ?? []).cast<String>())
          Padding(padding: const EdgeInsets.all(16), child: ErrorText(err)),
      ],
    );
  }

  List<Widget> _chatTiles(BuildContext context, Map<String, dynamic> login) {
    final t = Theme.of(context);
    final chats = (login['chats'] as List)
        .cast<Map>()
        .map((c) => c.cast<String, dynamic>())
        .where((c) {
          final problem =
              c['failed'] == true ||
              (c['has_room'] == true && ((c['stored'] as num?) ?? 0) > 0);
          return !_onlyProblems || problem;
        })
        .toList();
    return [
      if (_logins.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('${login['name']}', style: t.textTheme.labelLarge),
        ),
      if (chats.isEmpty) const ListTile(dense: true, title: Text('No chats')),
      for (final c in chats)
        ListTile(
          dense: true,
          leading: _chatIcon(context, c),
          title: Text(
            (c['name'] as String?)?.isNotEmpty == true
                ? c['name'] as String
                : _short(c['jid'] as String),
          ),
          subtitle: Text(_chatText(c)),
        ),
    ];
  }

  Widget _chatIcon(BuildContext context, Map<String, dynamic> c) {
    final stored = ((c['stored'] as num?) ?? 0).toInt();
    if (c['failed'] == true || (c['has_room'] == true && stored > 0)) {
      return Icon(
        Icons.warning_amber_rounded,
        color: Theme.of(context).colorScheme.error,
      );
    }
    if (c['has_room'] == true) {
      return const Icon(Icons.check_circle_outline, color: Colors.green);
    }
    return const Icon(Icons.schedule, color: Colors.grey);
  }

  String _chatText(Map<String, dynamic> c) {
    final stored = ((c['stored'] as num?) ?? 0).toInt();
    final parts = <String>[];
    if (c['has_room'] == true) {
      parts.add('${c['bridged']} in chat');
      if (stored > 0) parts.add('$stored not copied');
      if (c['rate_limit'] == true) {
        parts.add('stopped: rate limit');
      } else if (c['failed'] == true) {
        parts.add('stopped: error');
      }
    } else {
      parts.add(
        stored > 0
            ? 'no chat yet · $stored stored, copied when a new message arrives'
            : 'no chat yet',
      );
    }
    final ts = (c['last_msg_ts'] as num?)?.toInt() ?? 0;
    if (ts > 0) {
      parts.add(
        'last message ${_ago(DateTime.fromMillisecondsSinceEpoch(ts * 1000))}',
      );
    }
    return parts.join(' · ');
  }

  void _copy() {
    final log = _log;
    final summary = {
      'logins': [
        for (final l in _logins)
          {
            for (final k in [
              'rooms_pending',
              'pending_chunks',
              'conversations',
              'conversations_rooms',
              'stored_messages',
              'not_copied',
              'fillable',
              'blocked_chats',
              'rooms',
              'bridged_messages',
            ])
              k: l[k],
            'problem_chats': (l['chats'] as List)
                .cast<Map>()
                .where(
                  (c) =>
                      c['failed'] == true ||
                      (c['has_room'] == true &&
                          ((c['stored'] as num?) ?? 0) > 0),
                )
                .map(
                  (c) => {
                    'bridged': c['bridged'],
                    'stored': c['stored'],
                    'fillable': c['fillable'],
                    'newer_in_room':
                        ((c['room_newest'] as num?) ?? 0) >
                        ((c['last_msg_ts'] as num?) ?? 0),
                    'rate_limit': c['rate_limit'],
                  },
                )
                .toList(),
          },
      ],
      'log': {
        for (final k in [
          'progress',
          'saved',
          'save_failed',
          'ignored',
          'parse_dropped',
          'rooms_creating',
          'rooms_target',
          'rooms_done',
          'backfill_chats',
          'backfill_messages',
          'backfill_failed',
          'send_failed',
          'rate_limited',
        ])
          k: log[k],
        'chunks': log['chunks'],
        'errors': [
          for (final e in ((log['recent_errors'] as List?) ?? []).cast<Map>())
            '${e['msg']}: ${e['error'] ?? ''}',
        ],
      },
      'app_version': _appVersion,
      'fast_import': {
        for (final k in ['paused', 'import_done', 'pending', 'new_logins'])
          k: _dp[k],
      },
      'pace': {
        for (final e in _pace.entries)
          if (e.key != 'last_rate_limit') e.key: e.value,
      },
    };
    Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent(' ').convert(summary)),
    );
    toast(context, 'Summary copied (no names or numbers)');
  }

  static String _typeName(String t) => switch (t) {
    'INITIAL_BOOTSTRAP' => 'first chats',
    'RECENT' => 'recent',
    'FULL' => 'full history',
    _ => t.toLowerCase(),
  };

  static String _short(String jid) => jid.split('@').first;

  static String _time(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  static String _ago(DateTime d) {
    final s = DateTime.now().difference(d);
    if (s.inSeconds < 60) return '${s.inSeconds.clamp(0, 59)} s ago';
    if (s.inMinutes < 60) return '${s.inMinutes} min ago';
    if (s.inHours < 48) return '${s.inHours} h ago';
    return '${s.inDays} days ago';
  }
}

class _Phase extends StatelessWidget {
  final String title;
  final String text;
  final double? value; // null = indeterminate
  final bool done;
  final bool active;
  const _Phase({
    required this.title,
    required this.text,
    required this.value,
    required this.done,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 18,
              color: done ? Colors.green : t.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: t.textTheme.titleSmall)),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: done ? 1 : (active ? value : 0)),
        const SizedBox(height: 4),
        Text(text, style: t.textTheme.bodySmall),
      ],
    );
  }
}

class _Num extends StatelessWidget {
  final String label;
  final String value;
  final bool bad;
  const _Num(this.label, this.value, {this.bad = false});

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text(label),
    trailing: Text(
      value,
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: bad ? Theme.of(context).colorScheme.error : null,
      ),
    ),
  );
}
