// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/identity_server_lookup.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:matrix/matrix.dart' hide Contact;

class LocalContactsPage extends StatefulWidget {
  const LocalContactsPage({super.key});

  @override
  State<LocalContactsPage> createState() => _LocalContactsPageState();
}

class _LocalContactsPageState extends State<LocalContactsPage> {
  _Status _status = _Status.idle;
  String? _errorMessage;
  List<_ContactResult> _results = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _status = _Status.loading;
      _errorMessage = null;
    });

    final permissionGranted = await FlutterContacts.requestPermission(
      readonly: true,
    );
    if (!mounted) return;
    if (!permissionGranted) {
      setState(() {
        _status = _Status.error;
        _errorMessage = 'Contacts permission denied. '
            'Please grant it in your device settings.';
      });
      return;
    }

    final contacts = await FlutterContacts.getContacts(withProperties: true);
    if (!mounted) return;

    final emails = <String>[];
    final phones = <String>[];
    final addressToContact = <String, Contact>{};

    for (final contact in contacts) {
      for (final email in contact.emails) {
        final addr = email.address.trim().toLowerCase();
        if (addr.isNotEmpty) {
          emails.add(addr);
          addressToContact[addr] = contact;
        }
      }
      for (final phone in contact.phones) {
        final raw = phone.number.replaceAll(RegExp(r'[^\d+]'), '');
        if (raw.isNotEmpty) {
          phones.add(raw);
          addressToContact[raw] = contact;
        }
      }
    }

    if (emails.isEmpty && phones.isEmpty) {
      setState(() {
        _status = _Status.done;
        _results = [];
      });
      return;
    }

    final client = Matrix.of(context).client;
    Map<String, String> found;
    try {
      found = await lookupAddressesOnIS(client, emails, phones);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _Status.error;
        _errorMessage = 'Could not reach identity server: $e';
      });
      return;
    }

    if (!mounted) return;

    // Deduplicate by mxid (same person found via email + phone)
    final seen = <String>{};
    final results = <_ContactResult>[];
    for (final entry in found.entries) {
      if (seen.add(entry.value)) {
        final contact = addressToContact[entry.key];
        final medium = emails.contains(entry.key) ? 'email' : 'phone';
        results.add(
          _ContactResult(
            displayName: contact?.displayName ?? entry.key,
            mxid: entry.value,
            foundVia: medium,
            address: entry.key,
          ),
        );
      }
    }

    setState(() {
      _status = _Status.done;
      _results = results;
    });
  }

  void _openUser(String mxid) {
    UserDialog.show(context: context, profile: Profile(userId: mxid));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts on Matrix'),
        actions: [
          if (_status != _Status.loading)
            IconButton(
              icon: const Icon(Icons.refresh_outlined),
              tooltip: 'Refresh',
              onPressed: _load,
            ),
        ],
      ),
      body: switch (_status) {
        _Status.idle => const SizedBox.shrink(),
        _Status.loading => const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator.adaptive(),
                SizedBox(height: 16),
                Text('Searching your contacts on Matrix…'),
              ],
            ),
          ),
        _Status.error => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage ?? 'Unknown error',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_outlined),
                    label: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        _Status.done => _results.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.contacts_outlined, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        'None of your contacts were found on Matrix',
                        style: theme.textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This requires an identity server configured on your homeserver.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, i) {
                  final result = _results[i];
                  return ListTile(
                    leading: Avatar(
                      name: result.displayName,
                      presenceUserId: result.mxid,
                    ),
                    title: Text(result.displayName),
                    subtitle: Text(result.mxid),
                    trailing: _MediumBadge(medium: result.foundVia),
                    onTap: () => _openUser(result.mxid),
                  );
                },
              ),
      },
    );
  }
}

enum _Status { idle, loading, error, done }

class _ContactResult {
  final String displayName;
  final String mxid;
  final String foundVia;
  final String address;

  const _ContactResult({
    required this.displayName,
    required this.mxid,
    required this.foundVia,
    required this.address,
  });
}

class _MediumBadge extends StatelessWidget {
  final String medium;
  const _MediumBadge({required this.medium});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPhone = medium == 'phone';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isPhone
            ? theme.colorScheme.tertiaryContainer
            : theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPhone ? Icons.phone_outlined : Icons.email_outlined,
            size: 12,
            color: isPhone
                ? theme.colorScheme.onTertiaryContainer
                : theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            isPhone ? 'Phone' : 'Email',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isPhone
                  ? theme.colorScheme.onTertiaryContainer
                  : theme.colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
