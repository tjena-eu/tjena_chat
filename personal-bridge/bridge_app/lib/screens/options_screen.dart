import 'package:flutter/material.dart';

import '../native.dart';
import 'widgets.dart';

/// History (backfill) and WhatsApp status settings. These only change the
/// bridge's config file; the bridge itself is unmodified.
class OptionsScreen extends StatefulWidget {
  const OptionsScreen({super.key});
  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class BackfillPreset {
  final String id;
  final String title;
  final String text;
  final Map<String, dynamic>? values; // null = custom
  const BackfillPreset(this.id, this.title, this.text, this.values);
}

const backfillPresets = [
  BackfillPreset('off', 'Off', 'No old messages. Only new messages arrive.', {
    'enabled': false,
    'max_initial_messages': 0,
    'max_catchup_messages': 0,
    'max_initial_conversations': 10,
    'request_full_sync': false,
    'full_sync_days': 0,
  }),
  BackfillPreset('light', 'Light', 'Last 20 messages in your 10 most recent chats.', {
    'enabled': true,
    'max_initial_messages': 20,
    'max_catchup_messages': 100,
    'max_initial_conversations': 10,
    'request_full_sync': false,
    'full_sync_days': 0,
  }),
  BackfillPreset('standard', 'Standard', 'Last 50 messages in your 25 most recent chats.', {
    'enabled': true,
    'max_initial_messages': 50,
    'max_catchup_messages': 500,
    'max_initial_conversations': 25,
    'request_full_sync': false,
    'full_sync_days': 0,
  }),
  BackfillPreset('lots', 'Lots', 'Up to 500 messages in every chat, and a year of history from your phone.', {
    'enabled': true,
    'max_initial_messages': 500,
    'max_catchup_messages': 1000,
    'max_initial_conversations': -1,
    'request_full_sync': true,
    'full_sync_days': 365,
  }),
  BackfillPreset('custom', 'Custom', 'Choose the numbers yourself.', null),
];

/// Same defaults as the relay's DefaultBackfill.
Map<String, dynamic> get defaultBackfill => Map.of(backfillPresets[2].values!);

String presetFor(Map<String, dynamic> bf) {
  for (final p in backfillPresets) {
    final v = p.values;
    if (v != null && v.keys.every((k) => v[k] == bf[k])) return p.id;
  }
  return 'custom';
}

class _OptionsScreenState extends State<OptionsScreen> {
  Map<String, dynamic>? _backfill;
  String _status = 'off';
  bool _deleteOnLogout = true;
  String _preset = 'standard';
  bool _saving = false;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await Native.options();
      final bf = (o['backfill'] as Map?)?.cast<String, dynamic>() ?? defaultBackfill;
      setState(() {
        _backfill = {...defaultBackfill, ...bf};
        _preset = presetFor(_backfill!);
        _status = o['status_broadcast'] as String? ?? 'off';
        _deleteOnLogout = o['delete_chats_on_logout'] as bool? ?? true;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _change(void Function() fn) => setState(() {
        fn();
        _dirty = true;
      });

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await Native.setOptions({
        'backfill': _backfill,
        'status_broadcast': _status,
        'delete_chats_on_logout': _deleteOnLogout,
      });
      if (!mounted) return;
      setState(() => _dirty = false);
      toast(context, 'Saved. The bridge restarts to apply it.');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _number(String key, String label, String help, {int min = 0, int max = 10000, bool allowAll = false}) {
    final v = _backfill![key] as int? ?? 0;
    return ListTile(
      title: Text(label),
      subtitle: Text(help),
      trailing: SizedBox(
        width: 90,
        child: TextFormField(
          key: ValueKey('$key-$_preset'),
          initialValue: allowAll && v < 0 ? 'all' : '$v',
          textAlign: TextAlign.end,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(isDense: true, helperText: allowAll ? '"all" or number' : null),
          onChanged: (t) {
            final n = allowAll && t.trim().toLowerCase() == 'all' ? -1 : int.tryParse(t.trim());
            if (n == null || n > max || (n < min && !(allowAll && n == -1))) return;
            _change(() => _backfill![key] = n);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bf = _backfill;
    return Scaffold(
      appBar: AppBar(title: const Text('Chats & history')),
      floatingActionButton: _dirty
          ? FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            )
          : null,
      body: bf == null
          ? Center(child: _error != null ? ErrorText(_error!) : const CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                const SectionTitle('Message history (backfill)'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'How many old WhatsApp messages the bridge copies into tjena. Your phone sends the history once, '
                    'right after you link WhatsApp, so changes to the number of chats or "a year of history" only '
                    'apply the next time you link. Message counts apply to chats created from now on.',
                    style: t.textTheme.bodySmall,
                  ),
                ),
                RadioGroup<String>(
                  groupValue: _preset,
                  onChanged: (id) {
                    if (id == null) return;
                    final p = backfillPresets.firstWhere((p) => p.id == id);
                    _change(() {
                      _preset = id;
                      if (p.values != null) _backfill = Map.of(p.values!);
                    });
                  },
                  child: Column(children: [
                    for (final p in backfillPresets)
                      RadioListTile<String>(value: p.id, title: Text(p.title), subtitle: Text(p.text)),
                  ]),
                ),
                if (_preset == 'custom') ...[
                  SwitchListTile(
                    title: const Text('Copy old messages'),
                    value: bf['enabled'] == true,
                    onChanged: (v) => _change(() => bf['enabled'] = v),
                  ),
                  _number('max_initial_messages', 'Messages per new chat', 'Loaded when a chat is created'),
                  _number('max_catchup_messages', 'Missed messages per chat',
                      'Loaded after the bridge was offline'),
                  _number('max_initial_conversations', 'Chats after linking',
                      'Created right after linking; others appear with their next message',
                      min: 0, allowAll: true),
                  SwitchListTile(
                    title: const Text('Ask for a year of history'),
                    subtitle: const Text('Instead of about 3 months. Only when linking.'),
                    value: bf['request_full_sync'] == true,
                    onChanged: (v) => _change(() => bf['request_full_sync'] = v),
                  ),
                  if (bf['request_full_sync'] == true)
                    _number('full_sync_days', 'Days of history', '0 = WhatsApp decides', max: 3650),
                ],
                const SectionTitle('WhatsApp status updates'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Status updates (stories) from all your contacts arrive in one extra chat.',
                    style: t.textTheme.bodySmall,
                  ),
                ),
                RadioGroup<String>(
                  groupValue: _status,
                  onChanged: (v) => v == null ? null : _change(() => _status = v),
                  child: const Column(children: [
                    RadioListTile<String>(
                      value: 'off',
                      title: Text('Off (recommended)'),
                      subtitle: Text('Status updates are not bridged'),
                    ),
                    RadioListTile<String>(
                      value: 'muted',
                      title: Text('Muted chat'),
                      subtitle: Text('Bridged into a muted, low-priority chat'),
                    ),
                    RadioListTile<String>(
                      value: 'on',
                      title: Text('Normal chat'),
                      subtitle: Text('Bridged into a normal chat with notifications'),
                    ),
                  ]),
                ),
                if (_status == 'off')
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'If a "WhatsApp Status" chat already exists in tjena, leave it there to remove it.',
                      style: t.textTheme.bodySmall,
                    ),
                  ),
                const SectionTitle('Logging out an account'),
                SwitchListTile(
                  title: const Text('Remove its chats from tjena'),
                  subtitle: const Text(
                    'When you log a WhatsApp account out here, its chats and its space disappear from tjena. '
                    'Off: the chats stay readable but stop updating. If WhatsApp ends the session itself, '
                    'chats always stay, so linking again continues in them.',
                  ),
                  value: _deleteOnLogout,
                  onChanged: (v) => _change(() => _deleteOnLogout = v),
                ),
                if (_error != null) Padding(padding: const EdgeInsets.all(16), child: ErrorText(_error!)),
              ],
            ),
    );
  }
}
