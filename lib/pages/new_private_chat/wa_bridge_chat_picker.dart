// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../../utils/personal_bridge.dart';
import '../../widgets/avatar.dart';

/// New WhatsApp chat through a bridgev2 bridge (your own bridge at home):
/// pick one of your existing WhatsApp chats, or search your WhatsApp contacts
/// and start a chat. Contacts come from the bridge bot's `search` command and
/// chats are started with `start-chat`, so nothing in the bridge is changed.
class WaBridgeChatPicker extends StatefulWidget {
  final Client client;
  final String bot;
  const WaBridgeChatPicker({
    required this.client,
    required this.bot,
    super.key,
  });

  @override
  State<WaBridgeChatPicker> createState() => _WaBridgeChatPickerState();
}

class WaContact {
  final String id; // WhatsApp user id: phone digits or "lid-…"
  final String name;
  final String? roomId; // existing DM portal
  /// The own WhatsApp account (login ID) the contact was found in.
  final String? account;
  WaContact(this.id, this.name, this.roomId, {this.account});

  WaContact withAccount(String? account) =>
      WaContact(id, name, roomId, account: account);

  /// The name without the bridge's " (WA)" suffix.
  String get displayName => name.replaceFirst(RegExp(r'\s*\(WA\)$'), '');

  /// What `start-chat` accepts: "+" and the digits for a phone number, else the id.
  String get identifier => RegExp(r'^\d+$').hasMatch(id) ? '+$id' : id;
  String get label => RegExp(r'^\d+$').hasMatch(id) ? '+$id' : '';
}

/// Parses the bot's `search` reply. bridgev2 formats each result as
/// "* `ID` / [Name](matrix.to/#/@ghost) - DM portal: [Room](matrix.to/#/!room)".
List<WaContact> parseSearchReply(String? html, String? body) {
  final out = <WaContact>[];
  final text = html ?? body ?? '';
  final items = html != null
      ? RegExp(
          r'<li>(.*?)</li>',
          dotAll: true,
        ).allMatches(text).map((m) => m.group(1)!)
      : text.split('\n').where((l) => RegExp(r'^\s*[*-]\s').hasMatch(l));
  for (final item in items) {
    final id = RegExp(r'<code>([^<]+)</code>|`([^`]+)`').firstMatch(item);
    if (id == null) continue;
    final contactId = id.group(1) ?? id.group(2)!;
    String? name;
    String? room;
    for (final link in RegExp(
      r'<a href="([^"]+)">([^<]*)</a>|\[([^\]]*)\]\(([^)]+)\)',
    ).allMatches(item)) {
      final href = link.group(1) ?? link.group(4) ?? '';
      final label = link.group(2) ?? link.group(3) ?? '';
      final target = matrixToTarget(href);
      if (target == null) continue;
      if (target.startsWith('@')) name ??= label;
      if (target.startsWith('!')) room ??= target;
    }
    room ??= roomIdFromReply(null, item);
    if (name == null) {
      final plain = item.replaceAll(RegExp(r'<[^>]+>'), '');
      final slash = plain.indexOf(' / ');
      if (slash >= 0) {
        var rest = plain.substring(slash + 3);
        final portal = rest.indexOf(' - DM portal:');
        if (portal >= 0) rest = rest.substring(0, portal);
        name = rest.trim();
      }
    }
    out.add(WaContact(contactId, _unescape(name ?? ''), room));
  }
  return out;
}

/// "https://matrix.to/#/%21abc%3Aserver?via=x" → "!abc:server".
String? matrixToTarget(String href) {
  final m = RegExp(r'matrix\.to/#/([^?"\s)]+)').firstMatch(href);
  if (m == null) return null;
  try {
    return Uri.decodeComponent(m.group(1)!);
  } catch (_) {
    return m.group(1);
  }
}

/// The room id in a `start-chat` reply ("Created chat with …: [name](…/#/!room)").
String? roomIdFromReply(String? html, String? body) {
  for (final text in [html, body]) {
    if (text == null) continue;
    for (final m in RegExp(r'matrix\.to/#/[^"\s)]+').allMatches(text)) {
      final t = matrixToTarget(m.group(0)!);
      if (t != null && t.startsWith('!')) return t;
    }
  }
  return null;
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

class _WaBridgeChatPickerState extends State<WaBridgeChatPicker> {
  final _query = TextEditingController();
  String _filter = '';

  /// Search results per account tab (null key: only one account).
  final Map<String?, List<WaContact>> _contacts = {};
  String? _searchingIn;
  bool _searching = false;
  String? _busyId;
  String? _error;
  int _tab = 0;

  /// The bridge's WhatsApp logins (from `list-logins`).
  List<({String id, String name, String state})> _logins = const [];
  bool _loginsLoaded = false;

  Client get client => widget.client;

  /// One tab per account: the logins, plus accounts only seen in chats
  /// (while the bot hasn't answered yet).
  List<({String id, String name, String state})> get _accounts => [
    ..._logins,
    for (final a in WaAccounts.known(client, bot: widget.bot))
      if (!_logins.any((l) => l.id == a)) (id: a, name: '', state: ''),
  ];

  /// The account of the open tab; null with one account (commands then
  /// need no login ID).
  String? get _account {
    final accounts = _accounts;
    if (accounts.length < 2) return null;
    return accounts[_tab.clamp(0, accounts.length - 1)].id;
  }

  @override
  void initState() {
    super.initState();
    WaAccounts.ensureLoaded(client).then((_) {
      if (mounted) setState(() {});
    });
    _loadLogins();
  }

  Future<void> _loadLogins() async {
    try {
      final logins = await WaAccounts.fetch(client, widget.bot);
      if (!mounted) return;
      setState(() => _logins = logins);
    } catch (e) {
      Logs().w('[WaBridgeChatPicker] list-logins', e);
    } finally {
      if (mounted) setState(() => _loginsLoaded = true);
    }
  }

  /// The WhatsApp chats of [account] (all of them with one account).
  List<Room> _chatsOf(String? account) {
    final q = _filter.toLowerCase();
    return client.rooms.where((r) {
      if (r.membership != Membership.join || r.isSpace) return false;
      if (r.isDirectChat && r.directChatMatrixID == widget.bot) return false;
      if (RoomBridgeInfo.of(r)?.bridgeBot != widget.bot) return false;
      if (account != null && !WaAccounts.accountsOf(r).contains(account)) {
        return false;
      }
      return q.isEmpty || r.getLocalizedDisplayname().toLowerCase().contains(q);
    }).toList()..sort(
      (a, b) => b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime),
    );
  }

  Future<({String? html, String? body})?> _command(
    String command,
    bool Function(String) accept,
  ) async {
    final room = await BridgeBotChat.dm(client, widget.bot);
    return BridgeBotChat.commandFull(
      room,
      widget.bot,
      command,
      accept: accept,
      timeout: const Duration(seconds: 90),
    );
  }

  static const _noAnswer =
      'Your bridge did not answer. Is it online? (tjena may also be slowing '
      'down your messages while the bridge copies history: try again in a minute.)';

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.length < 2 || _searching) return;
    final acct = _account;
    setState(() {
      _searching = true;
      _searchingIn = acct;
      _error = null;
      _contacts.remove(acct);
    });
    try {
      final reply = await _command(
        acct == null ? 'search $q' : 'search $acct $q',
        BridgeBotChat.isSearchReply,
      );
      if (!mounted) return;
      if (reply == null) {
        setState(() => _error = _noAnswer);
        return;
      }
      final found = parseSearchReply(reply.html, reply.body);
      setState(() {
        _contacts[acct] = [for (final c in found) c.withAccount(acct)];
        if (found.isEmpty && !(reply.body ?? '').startsWith('Search results')) {
          _error = reply.body;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _start(
    String identifier, {
    String? account,
    String? knownRoom,
  }) async {
    if (knownRoom != null &&
        client.getRoomById(knownRoom)?.membership == Membership.join) {
      _open(knownRoom);
      return;
    }
    setState(() {
      _busyId = '$account/$identifier';
      _error = null;
    });
    try {
      final reply = await _command(
        account == null
            ? 'start-chat $identifier'
            : 'start-chat $account $identifier',
        BridgeBotChat.isStartChatReply,
      );
      final roomId = reply == null
          ? null
          : roomIdFromReply(reply.html, reply.body);
      if (roomId == null) {
        if (mounted) setState(() => _error = reply?.body ?? _noAnswer);
        return;
      }
      if (client.getRoomById(roomId)?.membership != Membership.join) {
        await client
            .waitForRoomInSync(roomId, join: true)
            .timeout(const Duration(seconds: 30));
      }
      if (mounted) _open(roomId);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the chat: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  static String _stateText(String state) => switch (state) {
    'CONNECTED' => 'Connected',
    'CONNECTING' || 'BACKFILLING' => 'Connecting…',
    'TRANSIENT_DISCONNECT' => 'Reconnecting…',
    'BAD_CREDENTIALS' ||
    'LOGGED_OUT' => 'Logged out: link it again in the bridge app',
    '' => 'Status unknown',
    _ => state,
  };

  void _open(String roomId) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.go('/rooms/$roomId');
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = _accounts;
    final multi = accounts.length > 1;
    if (_tab >= accounts.length) _tab = 0;
    final acct = _account;
    final login = multi ? accounts[_tab] : accounts.firstOrNull;
    final chats = _chatsOf(acct);
    final contacts = _contacts[acct];
    final digits = _query.text.replaceAll(RegExp(r'[\s\-()]'), '');
    final number = RegExp(r'^\+?\d{6,15}$').hasMatch(digits)
        ? (digits.startsWith('+') ? digits : '+$digits')
        : null;
    final where = acct == null ? '' : ' · ${WaAccounts.label(acct)}';

    return DefaultTabController(
      key: ValueKey(accounts.map((a) => a.id).join(',')),
      length: multi ? accounts.length : 1,
      initialIndex: multi ? _tab : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('WhatsApp chat'),
          bottom: multi
              ? TabBar(
                  isScrollable: accounts.length > 2,
                  onTap: (i) => setState(() {
                    _tab = i;
                    _error = null;
                  }),
                  tabs: [
                    for (final a in accounts)
                      Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.circle,
                              size: 8,
                              color: a.state == 'CONNECTED'
                                  ? Colors.green
                                  : theme.colorScheme.outline,
                            ),
                            const SizedBox(width: 6),
                            Text(WaAccounts.label(a.id)),
                          ],
                        ),
                      ),
                  ],
                )
              : null,
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Name or phone number',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: 'Search WhatsApp contacts',
                    icon: const Icon(Icons.person_search_outlined),
                    onPressed: _searching ? null : _search,
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _filter = v.trim()),
                onSubmitted: (_) => _search(),
              ),
            ),
            if (_searching || _busyId != null) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: ListView(
                children: [
                  if (login != null)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.phone_android,
                        color: login.state == 'CONNECTED'
                            ? Colors.green
                            : theme.colorScheme.outline,
                      ),
                      title: Text('Account ${WaAccounts.label(login.id)}'),
                      subtitle: Text(_stateText(login.state)),
                    )
                  else
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.info_outline),
                      title: Text(
                        _loginsLoaded
                            ? 'No WhatsApp account found (or the bridge did not answer).'
                            : 'Asking your bridge…',
                      ),
                    ),
                  if (number != null)
                    ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.dialpad_outlined),
                      ),
                      title: Text('Start chat with $number'),
                      subtitle: Text(
                        acct == null
                            ? 'Works for any number on WhatsApp'
                            : 'From your account ${WaAccounts.label(acct)}',
                      ),
                      trailing: _busyId == '$acct/$number'
                          ? const _Spinner()
                          : null,
                      onTap: _busyId != null
                          ? null
                          : () => _start(number, account: acct),
                    ),
                  _Header('Your WhatsApp chats$where (${chats.length})'),
                  if (chats.isEmpty)
                    const ListTile(
                      dense: true,
                      title: Text('No matching chats'),
                    ),
                  for (final r in chats.take(_filter.isEmpty ? 30 : 200))
                    ListTile(
                      leading: Avatar(
                        mxContent: r.avatar,
                        name: r.getLocalizedDisplayname(),
                      ),
                      title: Text(
                        r.getLocalizedDisplayname(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: r.isDirectChat
                          ? null
                          : Text(
                              WaAccounts.accountsOf(r).length > 1
                                  ? 'Group · in all your accounts'
                                  : 'Group',
                            ),
                      onTap: () => _open(r.id),
                    ),
                  _Header('WhatsApp contacts$where'),
                  if (contacts == null)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.info_outline),
                      title: Text(
                        _searching && _searchingIn == acct
                            ? 'Searching…'
                            : 'Type a name or number and press search to find contacts of this account.',
                      ),
                      onTap: _search,
                    )
                  else if (contacts.isEmpty)
                    const ListTile(
                      dense: true,
                      title: Text('No contacts found'),
                    )
                  else
                    for (final c in contacts)
                      ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            c.displayName.isNotEmpty
                                ? c.displayName.characters.first.toUpperCase()
                                : '#',
                          ),
                        ),
                        title: Text(
                          c.displayName.isNotEmpty
                              ? c.displayName
                              : c.label.isNotEmpty
                              ? c.label
                              : c.id,
                        ),
                        subtitle: Text(
                          [
                            if (c.label.isNotEmpty && c.displayName.isNotEmpty)
                              c.label,
                            if (c.roomId != null) 'chat exists',
                          ].join(' · '),
                        ),
                        trailing: _busyId == '${c.account}/${c.identifier}'
                            ? const _Spinner()
                            : const Icon(Icons.chat_bubble_outline),
                        onTap: _busyId != null
                            ? null
                            : () => _start(
                                c.identifier,
                                account: c.account,
                                knownRoom: c.roomId,
                              ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 20,
    height: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
