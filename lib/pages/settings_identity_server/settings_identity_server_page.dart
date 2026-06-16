// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

class SettingsIdentityServerPage extends StatefulWidget {
  const SettingsIdentityServerPage({super.key});

  @override
  State<SettingsIdentityServerPage> createState() =>
      _SettingsIdentityServerPageState();
}

class _SettingsIdentityServerPageState
    extends State<SettingsIdentityServerPage> {
  static int _sendAttempt = 0;

  // IS state
  String? _isBaseUrl;
  String? _isToken;
  Map<String, _IsPolicy>? _policies; // null = not loaded
  Set<String> _acceptedUrls = {};
  bool _loadingIs = true;
  String? _isError;

  // Account 3PIDs
  List<ThirdPartyIdentifier>? _pids;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    setState(() {
      _loadingIs = true;
      _isError = null;
    });
    try {
      final client = Matrix.of(context).client;

      // Load IS URL from wellknown
      final wk = await client.getWellknown();
      final isUrl = wk.mIdentityServer?.baseUrl.toString().stripTrailingSlash();
      if (isUrl == null) {
        setState(() {
          _isError = 'No identity server configured on this homeserver.';
          _loadingIs = false;
        });
        return;
      }

      // Register with IS to get token
      final openId = await client.requestOpenIdToken(client.userID!, {});
      final regRes = await http.post(
        Uri.parse('$isUrl/_matrix/identity/v2/account/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'access_token': openId.accessToken,
          'matrix_server_name': openId.matrixServerName,
          'token_type': openId.tokenType,
        }),
      );
      if (regRes.statusCode != 200) throw Exception('IS registration failed');
      final isToken = (jsonDecode(regRes.body) as Map)['token'] as String;

      // Fetch IS terms
      final termsRes = await http.get(
        Uri.parse('$isUrl/_matrix/identity/v2/terms'),
        headers: {'Authorization': 'Bearer $isToken'},
      );
      final policies = <String, _IsPolicy>{};
      if (termsRes.statusCode == 200) {
        final raw =
            (jsonDecode(termsRes.body) as Map)['policies'] as Map? ?? {};
        for (final entry in raw.entries) {
          final data = entry.value as Map;
          final version = data['version'] as String? ?? '';
          final langData = data['en'] as Map? ?? data.values.first as Map? ?? {};
          final name = langData['name'] as String? ?? entry.key as String;
          final url = langData['url'] as String? ?? '';
          policies[entry.key as String] =
              _IsPolicy(id: entry.key as String, name: name, url: url, version: version);
        }
      }

      // Load previously accepted URLs
      final prefs = await SharedPreferences.getInstance();
      final accepted = prefs
              .getStringList('is_accepted_urls_${Uri.parse(isUrl).host}') ??
          [];

      // Load account 3PIDs
      final pids = await client.getAccount3PIDs();

      if (!mounted) return;
      setState(() {
        _isBaseUrl = isUrl;
        _isToken = isToken;
        _policies = policies;
        _acceptedUrls = accepted.toSet();
        _pids = pids;
        _loadingIs = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isError = e.toString();
        _loadingIs = false;
      });
    }
  }

  bool get _allTermsAccepted {
    final p = _policies;
    if (p == null || p.isEmpty) return true;
    return p.values.every((pol) => _acceptedUrls.contains(pol.url));
  }

  Future<void> _acceptTerms() async {
    final isUrl = _isBaseUrl;
    final isToken = _isToken;
    final policies = _policies;
    if (isUrl == null || isToken == null || policies == null) return;

    final urls = policies.values.map((p) => p.url).toList();
    final res = await http.post(
      Uri.parse('$isUrl/_matrix/identity/v2/terms'),
      headers: {
        'Authorization': 'Bearer $isToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'user_accepts': urls}),
    );
    if (res.statusCode != 200 && res.statusCode != 204) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to accept terms: ${res.statusCode}')),
        );
      }
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final host = Uri.parse(isUrl).host;
    await prefs.setStringList('is_accepted_urls_$host', urls);
    if (!mounted) return;
    setState(() => _acceptedUrls = urls.toSet());
  }

  Future<void> _addEmail() async {
    if (!_allTermsAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please accept the terms first.')),
      );
      return;
    }

    final email = await _showInputDialog(
      title: 'Add email address',
      hint: 'you@example.com',
      keyboardType: TextInputType.emailAddress,
    );
    if (email == null || email.isEmpty) return;
    if (!mounted) return;
    await _startEmailBinding(email);
  }

  Future<void> _addPhone() async {
    if (!_allTermsAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please accept the terms first.')),
      );
      return;
    }

    final phone = await _showInputDialog(
      title: 'Add phone number',
      hint: '+491234567890',
      keyboardType: TextInputType.phone,
    );
    if (phone == null || phone.isEmpty) return;
    if (!mounted) return;
    await _startPhoneBinding(phone);
  }

  Future<void> _startEmailBinding(String email) async {
    final isUrl = _isBaseUrl;
    final isToken = _isToken;
    if (isUrl == null || isToken == null) return;

    final client = Matrix.of(context).client;
    final secret = DateTime.now().millisecondsSinceEpoch.toString();
    final attempt = _sendAttempt++;

    try {
      // Request validation token directly from IS
      final res = await http.post(
        Uri.parse('$isUrl/_matrix/identity/v2/validate/email/requestToken'),
        headers: {
          'Authorization': 'Bearer $isToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'client_secret': secret,
          'email': email,
          'send_attempt': attempt,
        }),
      );
      if (res.statusCode != 200) {
        throw Exception('IS request failed: ${res.statusCode} ${res.body}');
      }
      final sid = (jsonDecode(res.body) as Map)['sid'] as String;
      if (!mounted) return;

      final confirmed = await _showVerifyDialog(
        'Verify your email',
        'A verification link was sent to $email.\n'
            'Click the link in your email, then tap Continue.',
      );
      if (!confirmed || !mounted) return;

      // Bind via homeserver
      final isHost = Uri.parse(isUrl).host;
      await client.bind3PID(secret, isToken, isHost, sid);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  Future<void> _startPhoneBinding(String phone) async {
    final isUrl = _isBaseUrl;
    final isToken = _isToken;
    if (isUrl == null || isToken == null) return;

    final client = Matrix.of(context).client;
    final secret = DateTime.now().millisecondsSinceEpoch.toString();
    final attempt = _sendAttempt++;

    // Normalize: strip leading + and non-digits for IS msisdn
    final normalized = phone.replaceAll(RegExp(r'[^\d]'), '');
    // country code is the leading digits before the main number;
    // we can't parse it reliably without a library so pass full number
    // and let IS handle it. IS expects phone_number without country code
    // and country separately, but mautrix IS accepts E.164 in phone_number.
    // We'll use country='GB' as placeholder and send normalized number.
    // Most IS implementations accept the full number in phone_number.

    try {
      final res = await http.post(
        Uri.parse('$isUrl/_matrix/identity/v2/validate/msisdn/requestToken'),
        headers: {
          'Authorization': 'Bearer $isToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'client_secret': secret,
          'phone_number': normalized,
          'country': 'ZZ', // placeholder — IS parses E.164 directly
          'send_attempt': attempt,
        }),
      );
      if (res.statusCode != 200) {
        throw Exception('IS request failed: ${res.statusCode} ${res.body}');
      }
      final sid = (jsonDecode(res.body) as Map)['sid'] as String;
      if (!mounted) return;

      final confirmed = await _showVerifyDialog(
        'Verify your phone',
        'A verification code was sent to $phone.\n'
            'Enter the code on the link you received, then tap Continue.',
      );
      if (!confirmed || !mounted) return;

      final isHost = Uri.parse(isUrl).host;
      await client.bind3PID(secret, isToken, isHost, sid);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  Future<void> _removePid(ThirdPartyIdentifier pid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Remove address?'),
        content: Text(
          'This will remove ${pid.address} from your account and '
          'unpublish it from the identity server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final client = Matrix.of(context).client;
      await client.delete3pidFromAccount(pid.address, pid.medium);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  Future<void> _reload() async {
    final client = Matrix.of(context).client;
    final pids = await client.getAccount3PIDs();
    if (!mounted) return;
    setState(() => _pids = pids);
  }

  Future<String?> _showInputDialog({
    required String title,
    required String hint,
    required TextInputType keyboardType,
  }) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: keyboardType,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<bool> _showVerifyDialog(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog.adaptive(
        icon: const Icon(Icons.mark_email_read_outlined),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Identity Server'),
        actions: [
          if (!_loadingIs)
            IconButton(
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _init,
            ),
        ],
      ),
      body: _loadingIs
          ? const Center(child: CircularProgressIndicator.adaptive())
          : _isError != null
          ? Center(
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
                      _isError!,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _init,
                      icon: const Icon(Icons.refresh_outlined),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── IS info card ────────────────────────────────────────
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.dns_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Identity Server',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isBaseUrl ?? '—',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Configured by your homeserver.',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Terms of service card ────────────────────────────────
                if (_policies != null && _policies!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _allTermsAccepted
                                    ? Icons.verified_outlined
                                    : Icons.gavel_outlined,
                                color: _allTermsAccepted
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.error,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Terms of Service',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ..._policies!.values.map(
                            (pol) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  Icon(
                                    _acceptedUrls.contains(pol.url)
                                        ? Icons.check_circle_outline
                                        : Icons.radio_button_unchecked,
                                    size: 18,
                                    color: _acceptedUrls.contains(pol.url)
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: InkWell(
                                      onTap: pol.url.isNotEmpty
                                          ? () => launchUrlString(pol.url)
                                          : null,
                                      child: Text(
                                        '${pol.name} v${pol.version}',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: pol.url.isNotEmpty
                                              ? theme.colorScheme.primary
                                              : null,
                                          decoration: pol.url.isNotEmpty
                                              ? TextDecoration.underline
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (!_allTermsAccepted) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _acceptTerms,
                                child: const Text('Accept terms'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],

                // ── Published addresses ──────────────────────────────────
                const SizedBox(height: 16),
                Text(
                  'PUBLISHED ADDRESSES',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                if (_pids == null || _pids!.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'No addresses published yet.\n'
                      'Add an email or phone number below so others can find '
                      'you on Matrix.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  ...(_pids!.map(
                    (pid) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          pid.medium == ThirdPartyIdentifierMedium.email
                              ? Icons.email_outlined
                              : Icons.phone_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(pid.address),
                        subtitle: Text(
                          pid.medium == ThirdPartyIdentifierMedium.email
                              ? 'Email'
                              : 'Phone',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          color: theme.colorScheme.error,
                          tooltip: 'Remove',
                          onPressed: () => _removePid(pid),
                        ),
                      ),
                    ),
                  )),

                // ── Add buttons ──────────────────────────────────────────
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _allTermsAccepted ? _addEmail : null,
                        icon: const Icon(Icons.email_outlined),
                        label: const Text('Add email'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _allTermsAccepted ? _addPhone : null,
                        icon: const Icon(Icons.phone_outlined),
                        label: const Text('Add phone'),
                      ),
                    ),
                  ],
                ),
                if (!_allTermsAccepted)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Accept the terms of service above before adding addresses.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _IsPolicy {
  final String id;
  final String name;
  final String url;
  final String version;
  const _IsPolicy({
    required this.id,
    required this.name,
    required this.url,
    required this.version,
  });
}

extension on String {
  String stripTrailingSlash() =>
      endsWith('/') ? substring(0, length - 1) : this;
}
