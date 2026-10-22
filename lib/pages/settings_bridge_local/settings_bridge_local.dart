// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/bridge_keepalive.dart';
import 'package:fluffychat/utils/local_bridge_control.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import '../bridge/bridge_link_screen.dart';
import 'wa_chat_picker_screen.dart';

class SettingsBridgeLocal extends StatefulWidget {
  /// Which WhatsApp account this page manages ("default" = primary).
  final String accountId;
  const SettingsBridgeLocal({this.accountId = 'default', super.key});

  @override
  State<SettingsBridgeLocal> createState() => _SettingsBridgeLocalState();
}

class _SettingsBridgeLocalState extends State<SettingsBridgeLocal> {
  BridgeState _state = BridgeState.empty;
  StreamSubscription<BridgeEvent>? _sub;

  int _defaultDays = 30;
  bool _syncing = false;
  bool _cleaningEmpty = false;

  // Live history-sync progress (initial backfill into the cache). _histProgress
  // is WhatsApp's own 0–100 percentage (100 = done).
  int _histChats = 0;
  int _histMsgs = 0;
  int _histProgress = 0;
  bool _histSeen = false;

  @override
  void initState() {
    super.initState();
    _refreshState();
    _loadPrefs();
    // Seed from the bridge so the card survives navigating away and back.
    final p = WaMatrixBridge.instance.historyProgress(widget.accountId);
    if (p != null) {
      _histChats = p.chats;
      _histMsgs = p.messages;
      _histProgress = p.progress;
      _histSeen = true;
    }
    _sub = TjenaBridge.instance.events.listen((evt) {
      if (evt.type == BridgeEventType.state ||
          evt.type == BridgeEventType.linked ||
          evt.type == BridgeEventType.disconnected) {
        _refreshState();
      } else if (evt.type == BridgeEventType.historyProgress) {
        final acc = evt.data['account_id'] as String? ?? 'default';
        if (acc != widget.accountId || !mounted) return;
        setState(() {
          _histChats = (evt.data['chats'] as num?)?.toInt() ?? _histChats;
          _histMsgs = (evt.data['messages'] as num?)?.toInt() ?? _histMsgs;
          final p = (evt.data['progress'] as num?)?.toInt() ?? _histProgress;
          if (p >= _histProgress) _histProgress = p; // never go backwards
          _histSeen = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final days = await WaMatrixBridge.instance.getDefaultBackfillDays();
    if (!mounted) return;
    setState(() => _defaultDays = days);
  }

  bool _askedLinkMode = false;

  Future<void> _refreshState() async {
    try {
      final s = await TjenaBridge.instance.getState(accountID: widget.accountId);
      if (mounted) setState(() => _state = s);
      // First time we observe a linked account and the user hasn't chosen how to
      // handle history yet, ask.
      if (s.linked && !_askedLinkMode) {
        _askedLinkMode = true;
        final mode = await WaMatrixBridge.instance.getLinkMode();
        if (mode.isEmpty && mounted) {
          await _showPostLinkDialog();
        }
      }
    } catch (_) {}
  }

  Future<void> _showPostLinkDialog() async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('WhatsApp linked'),
        content: const Text(
          'Your WhatsApp history is being loaded into the app in the '
          'background.\n\nHow should chats appear?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('silent'),
            child: const Text('Only on new message'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('all'),
            child: const Text('Create all chats'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final days = await _promptDays(
      choice == 'all'
          ? 'How many days of history per chat?'
          : 'Default days of history to load when a chat first receives a message?',
    );
    if (days == null) return;
    await WaMatrixBridge.instance.setLinkMode(choice);
    await WaMatrixBridge.instance.setDefaultBackfillDays(days);
    if (choice == 'all') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Creating all chats from cached history…'),
        ),
      );
      // Give the link-time history sync a moment to populate the cache, then
      // create every cached chat. (Re-running later is safe — it skips existing.)
      Future.delayed(const Duration(seconds: 5), () async {
        final n = await WaMatrixBridge.instance.syncAllCachedChats(days, accountId: widget.accountId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Synced $n cached chats')),
          );
        }
      });
    }
  }

  Future<int?> _promptDays(String message) async {
    final controller = TextEditingController(text: '30');
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backfill history'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Days',
                border: OutlineInputBorder(),
                suffixText: 'days',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(0),
            child: const Text('No history'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(int.tryParse(controller.text.trim()) ?? 30),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openLink() async {
    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => BridgeLinkScreen(accountId: widget.accountId)),
    );
    if (linked == true) _refreshState();
  }

  /// Delete WhatsApp 1:1 chats that have no messages — the empty "phantom"
  /// chats that used to be created by protocol traffic from group participants.
  Future<void> _removeEmptyChats() async {
    setState(() => _cleaningEmpty = true);
    var removed = 0;
    try {
      removed = await WaMatrixBridge.instance.removeEmptyDirectChats();
    } catch (e) {
      if (!mounted) return;
      setState(() => _cleaningEmpty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove empty chats: $e')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _cleaningEmpty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed == 0
              ? 'No empty chats found.'
              : 'Removed $removed empty chat${removed == 1 ? '' : 's'}.',
        ),
      ),
    );
  }

  Future<void> _manualSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      // Refresh name and avatar for every known WA room.
      final client = Matrix.of(context).client;
      final waRooms = client.rooms.where(
        (r) => WaMatrixBridge.instance.isWaRoom(r.id),
      );
      for (final room in waRooms) {
        await WaMatrixBridge.instance.refreshRoom(room.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Refreshing names and avatars…')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _clearAllRooms() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('WA-Räume dieses Kontos löschen?'),
        content: const Text(
          'Entfernt nur die WhatsApp-Chatrooms dieses Kontos aus der App. '
          'Andere WhatsApp-Konten bleiben unberührt. '
          'Nichts wird in WhatsApp selbst geändert. '
          'Neue Nachrichten erstellen die Räume erneut.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final client = Matrix.of(context).client;
    await WaMatrixBridge.instance.clearAccountRooms(client, widget.accountId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('WA-Räume dieses Kontos entfernt')),
    );
  }

  Future<void> _unlink() async {
    final deleteChats = await confirmWaAccountRemoval(
      context,
      title: 'Unlink WhatsApp?',
      text: 'This disconnects WhatsApp on this device. Your WhatsApp account '
          'and other linked devices are not affected. You can re-link any time.',
      action: 'Unlink',
      deleteChatsDefault: false,
    );
    if (deleteChats == null || !mounted) return;
    await WaMatrixBridge.instance.unlinkAccount(
      Matrix.of(context).client,
      widget.accountId,
      deleteChats: deleteChats,
    );
    _refreshState();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Direct'),
        leading: BackButton(
          onPressed: () => context.go('/rooms/settings/local-bridges'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ConnectionCard(state: _state),
          const SizedBox(height: 12),
          const LocalBridgeBackgroundCard(),
          if (_histSeen) ...[
            const SizedBox(height: 12),
            Builder(builder: (context) {
              final done = _histProgress >= 100;
              return Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: done
                      ? Icon(Icons.check_circle_outline,
                          color: Theme.of(context).colorScheme.primary)
                      : const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                  title: Text(done
                      ? 'History loaded — safe to close'
                      : 'Loading WhatsApp history… $_histProgress%'),
                  subtitle: Text(
                      '$_histMsgs messages from $_histChats chats'
                      '${done ? '' : ' so far'}'),
                ),
              );
            }),
          ],
          const SizedBox(height: 20),
          _sectionLabel(context, 'ACTIONS'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!_state.linked)
                FilledButton.icon(
                  onPressed: _openLink,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Link WhatsApp'),
                ),
              if (_state.linked) ...[
                FilledButton.tonalIcon(
                  onPressed: _openLink,
                  icon: const Icon(Icons.manage_accounts_outlined, size: 18),
                  label: const Text('Manage / Re-link'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _state.connected ? _manualSync : null,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 18),
                  label: const Text('Sync chats'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _state.connected
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => WaChatPickerScreen(accountId: widget.accountId),
                            ),
                          )
                      : null,
                  icon: const Icon(Icons.checklist_outlined, size: 18),
                  label: const Text('Choose chats'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _cleaningEmpty ? null : _removeEmptyChats,
                  icon: _cleaningEmpty
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('Remove empty chats'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _clearAllRooms,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('WA-Räume dieses Kontos löschen'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _unlink,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  icon: const Icon(Icons.link_off, size: 18),
                  label: const Text('Unlink'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 24),
          _sectionLabel(context, 'SYNC & HISTORY'),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              title: const Text('Default backfill (days)'),
              subtitle: const Text(
                'History loaded when a chat is selected or first receives a '
                'message. 0 = none.',
              ),
              trailing: SizedBox(
                width: 80,
                child: _DaysField(
                  value: _defaultDays,
                  onChanged: (v) {
                    setState(() => _defaultDays = v);
                    WaMatrixBridge.instance.setDefaultBackfillDays(v);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          _sectionLabel(context, 'PROXY'),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _ProxySection(accountId: widget.accountId),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _DaysField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _DaysField({required this.value, required this.onChanged});

  @override
  State<_DaysField> createState() => _DaysFieldState();
}

class _DaysFieldState extends State<_DaysField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.value == 0 ? '' : widget.value.toString(),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      decoration: const InputDecoration(
        isDense: true,
        hintText: '∞',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      onChanged: (s) {
        final v = int.tryParse(s) ?? 0;
        widget.onChanged(v < 0 ? 0 : v);
      },
    );
  }
}

/// Shows whether the Android foreground service (and therefore the persistent
/// notification) is actually running. Without it the OS kills the bridge as
/// soon as the app is backgrounded, and the failure is otherwise completely
/// invisible — the notification simply never appears.
class LocalBridgeBackgroundCard extends StatefulWidget {
  const LocalBridgeBackgroundCard({super.key});

  @override
  State<LocalBridgeBackgroundCard> createState() => _LocalBridgeBackgroundCardState();
}

/// On/off switch for the keep-alive foreground service. Off means no
/// persistent notification, but WhatsApp/Signal only stay connected while the
/// app is open.
class _LocalBridgeBackgroundCardState extends State<LocalBridgeBackgroundCard> {
  bool? _running;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final running = await BridgeKeepAlive.isRunning;
    if (mounted) setState(() => _running = running);
  }

  Future<void> _set(bool on) async {
    setState(() => _busy = true);
    if (on) {
      final granted = await BridgeKeepAlive.ensureNotificationPermission();
      await LocalBridgeControl.setBackgroundService(true);
      if (!granted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              BridgeKeepAlive.lastError ??
                  'Allow notifications for Tjena in Android settings, '
                      'otherwise the background service cannot run.',
            ),
          ),
        );
      }
    } else {
      await LocalBridgeControl.setBackgroundService(false);
    }
    await _check();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfos.isAndroid) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final wanted = AppSettings.localBridgeBackgroundService.value;
    final running = _running;
    final String subtitle;
    if (!wanted) {
      subtitle = 'Off: no persistent notification, but WhatsApp and Signal '
          'only stay connected while Tjena is open.';
    } else if (running == true) {
      subtitle = 'Tjena stays connected while closed. Android requires the '
          'persistent notification for this.';
    } else if (running == false) {
      subtitle = BridgeKeepAlive.lastError ??
          'Not running yet. It starts once an account is linked. If it '
              'doesn\'t, allow notifications for Tjena.';
    } else {
      subtitle = 'Checking…';
    }
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        secondary: Icon(
          wanted && running == true
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          color: wanted && running != true
              ? theme.colorScheme.error
              : theme.colorScheme.primary,
        ),
        title: const Text('Run in background'),
        subtitle: Text(subtitle),
        isThreeLine: true,
        value: wanted,
        onChanged: _busy ? null : _set,
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  final BridgeState state;
  const _ConnectionCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconBg = state.linked
        ? const Color(0xFF25D366)
        : theme.colorScheme.surfaceContainerHighest;
    final iconFg =
        state.linked ? Colors.white : theme.colorScheme.onSurfaceVariant;

    String subtitle;
    if (!state.linked) {
      subtitle = 'Not linked';
    } else if (state.phone.isNotEmpty) {
      subtitle = state.phone;
      if (state.pushName.isNotEmpty) subtitle = '${state.pushName} · ${state.phone}';
    } else {
      subtitle = state.connected ? 'Connected' : 'Disconnected';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.chat_rounded, color: iconFg, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.phone.isNotEmpty
                        ? 'WhatsApp · ${state.phone}'
                        : 'WhatsApp Direct',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  _StatusBadge(state: state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _StatusBadge extends StatelessWidget {
  final BridgeState state;
  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!state.linked) {
      return _badge(
        context,
        'Not linked — tap Link WhatsApp',
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      );
    }
    if (state.connected) {
      return _badge(
        context,
        'Connected',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      );
    }
    return _badge(
      context,
      'Disconnected — will reconnect',
      theme.colorScheme.surfaceContainerHighest,
      theme.colorScheme.onSurfaceVariant,
    );
  }

  Widget _badge(BuildContext context, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// Proxy configuration for a WhatsApp account: enable + type/host/port/login.
/// Builds a proxy URL and applies it via the bridge (reconnects to take effect).
class _ProxySection extends StatefulWidget {
  final String accountId;
  const _ProxySection({required this.accountId});

  @override
  State<_ProxySection> createState() => _ProxySectionState();
}

class _ProxySectionState extends State<_ProxySection> {
  bool _enabled = false;
  String _type = 'socks5';
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  String get _k => 'wa_proxy_${widget.accountId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool('${_k}_enabled') ?? false;
    _type = p.getString('${_k}_type') ?? 'socks5';
    _host.text = p.getString('${_k}_host') ?? '';
    _port.text = p.getString('${_k}_port') ?? '';
    _user.text = p.getString('${_k}_user') ?? '';
    _pass.text = p.getString('${_k}_pass') ?? '';
    if (mounted) setState(() => _loaded = true);
  }

  String _buildUrl() {
    final host = _host.text.trim();
    if (!_enabled || host.isEmpty) return '';
    final auth = _user.text.isNotEmpty
        ? '${Uri.encodeComponent(_user.text)}:'
            '${Uri.encodeComponent(_pass.text)}@'
        : '';
    final port = _port.text.trim().isNotEmpty ? ':${_port.text.trim()}' : '';
    return '$_type://$auth$host$port';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final p = await SharedPreferences.getInstance();
    await p.setBool('${_k}_enabled', _enabled);
    await p.setString('${_k}_type', _type);
    await p.setString('${_k}_host', _host.text.trim());
    await p.setString('${_k}_port', _port.text.trim());
    await p.setString('${_k}_user', _user.text);
    await p.setString('${_k}_pass', _pass.text);
    String? error;
    try {
      await TjenaBridge.instance
          .setProxy(_buildUrl(), accountID: widget.accountId);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error != null
            ? 'Proxy error: $error'
            : _enabled
                ? 'Proxy saved — reconnecting…'
                : 'Proxy disabled.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox(height: 8);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use a proxy for WhatsApp'),
          subtitle: const Text('Route all WhatsApp traffic through a proxy'),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        if (_enabled) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DropdownButton<String>(
                value: _type,
                items: const [
                  DropdownMenuItem(
                      value: 'https', child: Text('HTTPS (TLS)')),
                  DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
                  DropdownMenuItem(value: 'http', child: Text('HTTP')),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'socks5'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: 'proxy.example.com',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _user,
            decoration:
                const InputDecoration(labelText: 'Username (optional)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration:
                const InputDecoration(labelText: 'Password (optional)'),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save proxy'),
          ),
        ),
      ],
    );
  }
}

/// Confirm dialog for removing/unlinking a built-in WhatsApp account, with the
/// choice to also remove its chats and space from tjena. Returns null when
/// cancelled, else whether to delete the chats.
Future<bool?> confirmWaAccountRemoval(
  BuildContext context, {
  required String title,
  required String text,
  required String action,
  required bool deleteChatsDefault,
}) {
  var deleteChats = deleteChatsDefault;
  return showDialog<bool?>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: deleteChats,
              onChanged: (v) => setState(() => deleteChats = v ?? false),
              title: const Text('Also remove its chats and space from tjena'),
              subtitle: const Text('WhatsApp itself keeps all messages.'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, deleteChats),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}
