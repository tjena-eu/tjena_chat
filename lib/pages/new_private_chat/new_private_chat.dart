// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/new_private_chat/new_private_chat_view.dart';
import 'package:fluffychat/pages/new_private_chat/qr_scanner_modal.dart';
import 'package:fluffychat/pages/settings_bridges/bridge_definition.dart';
import 'package:fluffychat/pages/settings_bridge_local/wa_chat_picker_screen.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/utils/signal_matrix_bridge.dart';
import 'package:fluffychat/utils/wa_matrix_bridge.dart';
import 'package:tjena_bridge/tjena_bridge.dart';
import 'package:fluffychat/utils/identity_server_lookup.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/adaptive_dialogs/user_dialog.dart';

class NewPrivateChat extends StatefulWidget {
  final String? deeplink;
  const NewPrivateChat({super.key, required this.deeplink});

  @override
  NewPrivateChatController createState() => NewPrivateChatController();
}

class NewPrivateChatController extends State<NewPrivateChat> {
  final TextEditingController controller = TextEditingController();
  final FocusNode textFieldFocus = FocusNode();

  Future<List<Profile>>? searchResponse;

  Timer? _searchCoolDown;

  static const Duration _coolDown = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();

    final deeplink = widget.deeplink;
    if (deeplink != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        UrlLauncher(context, deeplink).openMatrixToUrl();
      });
    }
  }

  Future<void> searchUsers([String? input]) async {
    final searchTerm = input ?? controller.text;
    if (searchTerm.isEmpty) {
      _searchCoolDown?.cancel();
      setState(() {
        searchResponse = _searchCoolDown = null;
      });
      return;
    }

    _searchCoolDown?.cancel();
    _searchCoolDown = Timer(_coolDown, () {
      setState(() {
        searchResponse = _searchUser(searchTerm);
      });
    });
  }

  Future<List<Profile>> _searchUser(String searchTerm) async {
    final client = Matrix.of(context).client;
    final result = await client.searchUserDirectory(searchTerm);
    final profiles = result.results;

    if (searchTerm.isValidMatrixId &&
        searchTerm.sigil == '@' &&
        !profiles.any((profile) => profile.userId == searchTerm)) {
      profiles.add(Profile(userId: searchTerm));
    }

    // If the term looks like an email, also query the identity server
    if (_looksLikeEmail(searchTerm)) {
      try {
        final found = await lookupAddressesOnIS(
          client,
          [searchTerm],
          [],
        );
        final mxid = found[searchTerm.toLowerCase()];
        if (mxid != null && !profiles.any((p) => p.userId == mxid)) {
          profiles.insert(0, Profile(userId: mxid, displayName: searchTerm));
        }
      } catch (_) {}
    }

    return profiles;
  }

  static bool _looksLikeEmail(String s) {
    final at = s.indexOf('@');
    return at > 0 && s.contains('.', at);
  }

  void inviteAction() => FluffyShare.shareInviteLink(context);

  Future<void> openScannerAction() async {
    final l10n = L10n.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (PlatformInfos.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (!mounted) return;
      if (info.version.sdkInt < 21) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(l10n.unsupportedAndroidVersionLong)),
        );
        return;
      }
    }
    if (!mounted) return;
    await showAdaptiveBottomSheet(
      context: context,
      builder: (_) => QrScannerModal(
        onScan: (link) => UrlLauncher(context, link).openMatrixToUrl(),
      ),
    );
  }

  Future<void> copyUserId() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    await Clipboard.setData(
      ClipboardData(text: Matrix.of(context).client.userID!),
    );
    if (!mounted) return;
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text(l10n.copiedToClipboard)),
    );
  }

  void openUserModal(Profile profile) =>
      UserDialog.show(context: context, profile: profile);

  List<BridgeDef> availableBridges() {
    final client = Matrix.of(context).client;
    final domain = client.userID?.domain ?? '';
    return kBridges.where((def) {
      final botId = def.botUserId(domain);
      return client.rooms.any(
        (r) => r.isDirectChat && r.directChatMatrixID == botId,
      );
    }).toList();
  }

  /// WhatsApp "new chat" entry: choose an existing chat from the list, or enter
  /// a phone number.
  Future<void> openWhatsAppNewChat() async {
    // Pick which WhatsApp account first (multi-account support).
    final accounts = await TjenaBridge.instance.listAccounts();
    if (!mounted) return;
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No WhatsApp account linked yet.')),
      );
      return;
    }
    var accountId = accounts.first['id'] as String? ?? 'default';
    if (accounts.length > 1) {
      final selected = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                  dense: true, title: Text('Choose WhatsApp account')),
              const Divider(height: 1),
              ...accounts.map((a) {
                final id = a['id'] as String? ?? 'default';
                final phone = a['phone'] as String? ?? '';
                return ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(phone.isNotEmpty ? '+$phone' : 'WhatsApp ($id)'),
                  onTap: () => Navigator.pop(ctx, id),
                );
              }),
            ],
          ),
        ),
      );
      if (!mounted || selected == null) return;
      accountId = selected;
    }

    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              dense: true,
              title: Text('Start a WhatsApp chat'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: const Text('Choose an existing chat'),
              subtitle: const Text('Pick from your WhatsApp chats'),
              onTap: () => Navigator.pop(ctx, 'existing'),
            ),
            ListTile(
              leading: const Icon(Icons.dialpad_outlined),
              title: const Text('Enter a phone number'),
              subtitle: const Text('Start a chat with a number'),
              onTap: () => Navigator.pop(ctx, 'phone'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'phone') {
      await openLocalBridgeChat(isSig: false, accountId: accountId);
    } else if (choice == 'existing') {
      final roomId = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) =>
              WaChatPickerScreen(pickToOpen: true, accountId: accountId),
        ),
      );
      if (roomId != null && roomId.isNotEmpty && mounted) {
        context.go('/rooms/$roomId');
      }
    }
  }

  Future<void> openLocalBridgeChat(
      {required bool isSig, String accountId = 'default'}) async {
    final phone = await _showPhoneDialog(
      isSig ? 'Signal chat' : 'WhatsApp chat',
    );
    if (phone == null || phone.isEmpty || !mounted) return;
    final roomId = isSig
        ? SignalMatrixBridge.instance.matrixRoomIdForPhone(phone)
        : WaMatrixBridge.instance
            .ensureChatForPhone(phone, accountId: accountId);
    if (roomId != null && mounted) {
      context.go('/rooms/$roomId');
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isSig
                ? 'No Signal chat found for $phone. '
                    'Send or receive a message via Signal first.'
                : 'WhatsApp bridge not connected yet. Try again in a moment.',
          ),
        ),
      );
    }
  }

  Future<void> openBridgeNewChat(BridgeDef def) async {
    final phone = await _showPhoneDialog('New ${def.name} chat');
    if (phone == null || phone.isEmpty) return;

    final client = Matrix.of(context).client;
    final domain = client.userID?.domain ?? '';
    final botId = def.botUserId(domain);

    var dmRoom = client.rooms.firstWhereOrNull(
      (r) => r.isDirectChat && r.directChatMatrixID == botId,
    );
    dmRoom ??= client.getRoomById(await client.startDirectChat(botId));

    if (dmRoom == null || !mounted) return;
    await dmRoom.sendTextEvent('${def.pmCommand} $phone');

    if (!mounted) return;
    context.go('/rooms/${dmRoom.id}'); // ignore: use_build_context_synchronously
  }

  Future<String?> _showPhoneDialog(String title) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '+1234567890',
            labelText: 'Phone number with country code',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Start chat'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => NewPrivateChatView(this);
}
