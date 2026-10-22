// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/local_bridge_control.dart';
import 'package:fluffychat/utils/wa_call_link.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tjena_bridge/tjena_bridge.dart';

import '../bridge/bridge_link_screen.dart';
import 'settings_bridge_local.dart';

/// Hub for the on-device (local) bridges. WhatsApp supports multiple accounts;
/// Signal is a single account. Each entry opens its own settings (link /
/// disconnect, resync, choose chats, …).
class LocalBridgesHub extends StatefulWidget {
  const LocalBridgesHub({super.key});

  @override
  State<LocalBridgesHub> createState() => _LocalBridgesHubState();
}

class _LocalBridgesHubState extends State<LocalBridgesHub> {
  StreamSubscription<BridgeEvent>? _sub;
  List<Map<String, dynamic>> _waAccounts = [];
  SignalBridgeState _sig = SignalBridgeState.empty;
  bool _busy = false;
  bool _waCallsEnabled = AppSettings.waCallsEnabled.value;
  bool _autoReply = AppSettings.waCallAutoReply.value;
  bool _autoDecline = AppSettings.waCallAutoDecline.value;
  String _autoReplyMsg = AppSettings.waCallAutoReplyMessage.value;
  bool? _callOnline; // null = checking

  @override
  void initState() {
    super.initState();
    _refresh();
    _checkCallFeature();
    _sub = TjenaBridge.instance.events.listen((_) => _refresh());
  }

  Future<void> _checkCallFeature() async {
    final online = await callFeatureOnline();
    if (mounted) setState(() => _callOnline = online);
  }

  Future<void> _editAutoReplyMessage() async {
    final controller = TextEditingController(text: _autoReplyMsg);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Auto-reply message'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Sent to people who call you on WhatsApp. The call link is added '
              'automatically on the next line.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Your message…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final msg = result.trim();
    setState(() => _autoReplyMsg = msg);
    await AppSettings.waCallAutoReplyMessage.setItem(msg);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final accounts = await TjenaBridge.instance.listAccounts();
      final sig = await TjenaBridge.instance.getSignalState();
      if (mounted) {
        setState(() {
          _waAccounts = accounts;
          _sig = sig;
        });
      }
    } catch (_) {}
  }

  Future<void> _addAccount() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final id = await TjenaBridge.instance.addAccount();
      if (id.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not create account')),
          );
        }
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => BridgeLinkScreen(accountId: id)),
      );
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAccount(String id) async {
    final deleteChats = await confirmWaAccountRemoval(
      context,
      title: 'Remove account?',
      text: 'Logs out and removes this WhatsApp account from the app. '
          'WhatsApp itself is unaffected.',
      action: 'Remove',
      deleteChatsDefault: true,
    );
    if (deleteChats == null || !mounted) return;
    await WaMatrixBridge.instance.removeAccount(
      Matrix.of(context).client,
      id,
      deleteChats: deleteChats,
    );
    await _refresh();
  }

  String _accSubtitle(Map<String, dynamic> a) {
    final linked = a['linked'] as bool? ?? false;
    final connected = a['connected'] as bool? ?? false;
    final phone = a['phone'] as String? ?? '';
    if (!linked) return 'Not linked — tap to set up';
    final who = phone.isNotEmpty ? phone : 'linked';
    return connected ? 'Connected · $who' : 'Linked · $who (offline)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color dot(bool connected, bool linked) => connected
        ? const Color(0xFF25D366)
        : (linked ? Colors.orange : theme.colorScheme.outline);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Built-in bridges'),
        leading: BackButton(
          onPressed: () => context.go('/rooms/settings/bridges'),
        ),
      ),
      body: !LocalBridgeControl.enabled
          ? _DisabledNotice(
              onEnable: () async {
                await LocalBridgeControl.setEnabled(true);
                if (mounted) setState(() {});
                await _refresh();
              },
            )
          : ListView(
              children: [
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  color: theme.colorScheme.tertiaryContainer,
                  child: ListTile(
                    leading: Icon(
                      Icons.science_outlined,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                    title: Text(
                      'Experimental, being phased out',
                      style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                    subtitle: Text(
                      'These bridges run inside this app on this phone. They will be '
                      'replaced by your own bridge (tjena Bridge app), which works '
                      'on all your devices.',
                      style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: () => context.go('/rooms/settings/bridges'),
                      child: const Text('Options'),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: LocalBridgeBackgroundCard(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'WHATSAPP ACCOUNTS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                for (final a in _waAccounts)
                  Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF25D366),
                        child: const Icon(
                          Icons.chat_rounded,
                          color: Colors.white,
                        ),
                      ),
                      title: Text(
                        (a['id'] as String? ?? '') == 'default'
                            ? 'WhatsApp'
                            : 'WhatsApp (${(a['phone'] as String?)?.isNotEmpty == true ? a['phone'] : 'account'})',
                      ),
                      subtitle: Text(_accSubtitle(a)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.circle,
                            size: 12,
                            color: dot(
                              a['connected'] as bool? ?? false,
                              a['linked'] as bool? ?? false,
                            ),
                          ),
                          if ((a['id'] as String? ?? '') != 'default')
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  _removeAccount(a['id'] as String? ?? ''),
                            ),
                        ],
                      ),
                      onTap: () => context.go(
                        '/rooms/settings/bridge-local?account=${a['id']}',
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _addAccount,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add),
                    label: const Text('Add WhatsApp account'),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'SIGNAL',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF3A76F0),
                      child: Icon(
                        Icons.signal_cellular_alt,
                        color: Colors.white,
                      ),
                    ),
                    title: const Text('Signal'),
                    subtitle: Text(
                      !_sig.linked
                          ? 'Not linked'
                          : (_sig.connected
                                ? 'Connected · ${_sig.phone}'
                                : 'Linked · ${_sig.phone} (offline)'),
                    ),
                    trailing: Icon(
                      Icons.circle,
                      size: 12,
                      color: dot(_sig.connected, _sig.linked),
                    ),
                    onTap: () => context.go('/rooms/settings/signal'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'WHATSAPP CALLS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.call_outlined),
                        title: const Text('WhatsApp web calls'),
                        subtitle: const Text(
                          'Show a call button in WhatsApp chats that sends the '
                          'contact a web call link.',
                        ),
                        value: _waCallsEnabled,
                        onChanged: (v) {
                          setState(() => _waCallsEnabled = v);
                          AppSettings.waCallsEnabled.setItem(v);
                          if (v) _checkCallFeature();
                        },
                      ),
                      if (_waCallsEnabled) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(
                            _callOnline == null
                                ? Icons.hourglass_empty
                                : (_callOnline!
                                      ? Icons.cloud_done_outlined
                                      : Icons.cloud_off_outlined),
                            color: _callOnline == null
                                ? theme.colorScheme.onSurfaceVariant
                                : (_callOnline!
                                      ? Colors.green
                                      : theme.colorScheme.error),
                          ),
                          title: Text(
                            _callOnline == null
                                ? 'Checking call service…'
                                : (_callOnline!
                                      ? 'Call service online'
                                      : 'Call service offline'),
                          ),
                          subtitle: Text(
                            AppSettings.callProvisionerBaseUrl.value,
                          ),
                          trailing: IconButton(
                            tooltip: 'Recheck',
                            icon: const Icon(Icons.refresh),
                            onPressed: () {
                              setState(() => _callOnline = null);
                              _checkCallFeature();
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          secondary: const Icon(Icons.reply_outlined),
                          title: const Text('Auto-reply to WhatsApp calls'),
                          subtitle: const Text(
                            'When someone calls you on WhatsApp, automatically send '
                            'them a message that you don’t take WhatsApp calls, with '
                            'a link to call you instead.',
                          ),
                          value: _autoReply,
                          onChanged: (v) {
                            setState(() => _autoReply = v);
                            AppSettings.waCallAutoReply.setItem(v);
                          },
                        ),
                        if (_autoReply)
                          ListTile(
                            leading: const Icon(Icons.edit_outlined),
                            title: const Text('Auto-reply message'),
                            subtitle: Text(
                              _autoReplyMsg.isEmpty
                                  ? '(only the call link)'
                                  : _autoReplyMsg,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _editAutoReplyMessage,
                          ),
                        const Divider(height: 1),
                        SwitchListTile(
                          secondary: const Icon(Icons.call_end_outlined),
                          title: const Text('Auto-decline WhatsApp calls'),
                          subtitle: const Text(
                            'Also decline the incoming WhatsApp call so it stops '
                            'ringing.',
                          ),
                          value: _autoDecline,
                          onChanged: (v) {
                            setState(() => _autoDecline = v);
                            AppSettings.waCallAutoDecline.setItem(v);
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _DisabledNotice extends StatelessWidget {
  final VoidCallback onEnable;
  const _DisabledNotice({required this.onEnable});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.science_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Built-in bridges are off',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'The built-in WhatsApp/Signal bridge is experimental and being '
              'phased out. Use your own bridge (tjena Bridge app) or the tjena '
              'server bridge instead.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go('/rooms/settings/bridges'),
              child: const Text('Bridge options'),
            ),
            TextButton(
              onPressed: onEnable,
              child: const Text('Turn on anyway'),
            ),
          ],
        ),
      ),
    );
  }
}
