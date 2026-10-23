// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
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
  WaContact(this.id, this.name, this.roomId);

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
      final plain = RegExp(
        r'/\s*([^<\-\[]+)',
      ).firstMatch(item.replaceAll(RegExp(r'<[^>]+>'), ''));
      name = plain?.group(1)?.trim();
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
  List<WaContact>? _contacts;
  bool _searching = false;
  String? _busyId;
  String? _error;

  Client get client => widget.client;

  List<Room> get _chats {
    final q = _filter.toLowerCase();
    final rooms =
        client.rooms.where((r) {
          if (r.membership != Membership.join || r.isSpace) return false;
          if (r.isDirectChat && r.directChatMatrixID == widget.bot) {
            return false;
          }
          if (RoomBridgeInfo.of(r)?.bridgeBot != widget.bot) return false;
          return q.isEmpty ||
              r.getLocalizedDisplayname().toLowerCase().contains(q);
        }).toList()..sort(
          (a, b) =>
              b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime),
        );
    return rooms;
  }

  /// Sends a bot command and returns (formatted_body, body) of its reply.
  Future<({String? html, String? body})?> _command(String command) async {
    final room = await BridgeBotChat.dm(client, widget.bot);
    final sentAfter = DateTime.now().subtract(const Duration(seconds: 1));
    final completer = Completer<({String? html, String? body})?>();
    final sub = client.onTimelineEvent.stream.listen((e) {
      if (e.roomId != room.id || e.senderId != widget.bot) return;
      if (e.originServerTs.isBefore(sentAfter) ||
          e.type != EventTypes.Message) {
        return;
      }
      if (!completer.isCompleted) {
        completer.complete((
          html: e.content['formatted_body'] as String?,
          body: e.body,
        ));
      }
    });
    try {
      await room.sendTextEvent(command);
      return await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => null,
      );
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.length < 2) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final reply = await _command('search $q');
      if (!mounted) return;
      if (reply == null) {
        setState(() => _error = 'Your bridge did not answer. Is it online?');
      } else {
        final found = parseSearchReply(reply.html, reply.body);
        setState(() {
          _contacts = found;
          if (found.isEmpty &&
              !(reply.body ?? '').startsWith('Search results')) {
            _error = reply.body;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _start(String identifier, {String? knownRoom}) async {
    if (knownRoom != null &&
        client.getRoomById(knownRoom)?.membership == Membership.join) {
      _open(knownRoom);
      return;
    }
    setState(() {
      _busyId = identifier;
      _error = null;
    });
    try {
      final reply = await _command('start-chat $identifier');
      final roomId = reply == null
          ? null
          : roomIdFromReply(reply.html, reply.body);
      if (roomId == null) {
        if (mounted) {
          setState(
            () => _error =
                reply?.body ?? 'Your bridge did not answer. Is it online?',
          );
        }
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
    final chats = _chats;
    final digits = _query.text.replaceAll(RegExp(r'[\s\-()]'), '');
    final looksLikeNumber = RegExp(r'^\+?\d{6,15}$').hasMatch(digits);
    final number = looksLikeNumber
        ? (digits.startsWith('+') ? digits : '+$digits')
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('WhatsApp chat')),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                if (number != null)
                  ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.dialpad_outlined),
                    ),
                    title: Text('Start chat with $number'),
                    subtitle: const Text('Works for any number on WhatsApp'),
                    onTap: _busyId != null ? null : () => _start(number),
                  ),
                _Header('Your WhatsApp chats (${chats.length})'),
                if (chats.isEmpty)
                  const ListTile(dense: true, title: Text('No matching chats')),
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
                    onTap: () => _open(r.id),
                  ),
                _Header('WhatsApp contacts'),
                if (_contacts == null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.info_outline),
                    title: const Text(
                      'Type a name or number and press search to find WhatsApp contacts.',
                    ),
                    onTap: _search,
                  )
                else if (_contacts!.isEmpty)
                  const ListTile(dense: true, title: Text('No contacts found'))
                else
                  for (final c in _contacts!)
                    ListTile(
                      leading: CircleAvatar(
                        child: Text(
                          c.name.isNotEmpty
                              ? c.name.characters.first.toUpperCase()
                              : '#',
                        ),
                      ),
                      title: Text(
                        c.name.isNotEmpty
                            ? c.name
                            : c.label.isNotEmpty
                            ? c.label
                            : c.id,
                      ),
                      subtitle: Text(
                        [
                          if (c.label.isNotEmpty && c.name.isNotEmpty) c.label,
                          if (c.roomId != null) 'chat exists',
                        ].join(' · '),
                      ),
                      trailing: _busyId == c.identifier
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chat_bubble_outline),
                      onTap: _busyId != null
                          ? null
                          : () => _start(c.identifier, knownRoom: c.roomId),
                    ),
              ],
            ),
          ),
        ],
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
