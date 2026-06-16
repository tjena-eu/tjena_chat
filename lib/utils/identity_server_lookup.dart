// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kCustomIsUrlKey = 'custom_is_base_url';

/// Returns the effective IS base URL: the user's custom override if set,
/// otherwise the homeserver's well-known value. Returns null if neither exists.
Future<String?> getEffectiveIsUrl(Client client) async {
  final prefs = await SharedPreferences.getInstance();
  final custom = prefs.getString(_kCustomIsUrlKey);
  if (custom != null && custom.isNotEmpty) {
    return _strip(custom);
  }
  try {
    final wk = await client.getWellknown();
    final url = wk.mIdentityServer?.baseUrl.toString();
    return url != null ? _strip(url) : null;
  } catch (_) {
    return null;
  }
}

Future<void> setCustomIsUrl(String? url) async {
  final prefs = await SharedPreferences.getInstance();
  if (url == null || url.isEmpty) {
    await prefs.remove(_kCustomIsUrlKey);
  } else {
    await prefs.setString(_kCustomIsUrlKey, _strip(url));
  }
}

String _strip(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

/// Looks up a list of email/phone addresses against the identity server using
/// the IS v2 hashed lookup API (MSC2134).
///
/// Uses the user's custom IS URL if configured, otherwise the homeserver's
/// well-known value. Returns a map of lowercase(address) → mxid.
Future<Map<String, String>> lookupAddressesOnIS(
  Client client,
  List<String> emails,
  List<String> phones,
) async {
  final isBaseUrl = await getEffectiveIsUrl(client);
  if (isBaseUrl == null) return {};

  final userId = client.userID;
  if (userId == null) return {};

  // 1. Get OpenID token from homeserver
  final openIdCreds = await client.requestOpenIdToken(userId, {});

  // 2. Register with IS to get an IS access token
  final registerRes = await http.post(
    Uri.parse('$isBaseUrl/_matrix/identity/v2/account/register'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'access_token': openIdCreds.accessToken,
      'matrix_server_name': openIdCreds.matrixServerName,
      'token_type': openIdCreds.tokenType,
    }),
  );
  if (registerRes.statusCode != 200) return {};
  final isToken =
      (jsonDecode(registerRes.body) as Map<String, dynamic>)['token']
          as String?;
  if (isToken == null) return {};

  final authHeader = {'Authorization': 'Bearer $isToken'};

  // 3. Accept IS terms (idempotent — IS remembers per-account, but some
  //    implementations require acceptance with every new token session).
  final termsRes = await http.get(
    Uri.parse('$isBaseUrl/_matrix/identity/v2/terms'),
    headers: authHeader,
  );
  if (termsRes.statusCode == 200) {
    final policies =
        (jsonDecode(termsRes.body) as Map<String, dynamic>)['policies']
            as Map<String, dynamic>?;
    if (policies != null && policies.isNotEmpty) {
      final urls = <String>[];
      for (final policy in policies.values) {
        if (policy is Map) {
          for (final lang in policy.values) {
            if (lang is Map) {
              final url = lang['url'] as String?;
              if (url != null && url.isNotEmpty) urls.add(url);
            }
          }
        }
      }
      if (urls.isNotEmpty) {
        await http.post(
          Uri.parse('$isBaseUrl/_matrix/identity/v2/terms'),
          headers: {...authHeader, 'Content-Type': 'application/json'},
          body: jsonEncode({'user_accepts': urls}),
        );
      }
    }
  }

  // 4. Get hashing parameters
  final hashDetailsRes = await http.get(
    Uri.parse('$isBaseUrl/_matrix/identity/v2/hash_details'),
    headers: authHeader,
  );
  if (hashDetailsRes.statusCode != 200) return {};
  final hashDetails =
      jsonDecode(hashDetailsRes.body) as Map<String, dynamic>;
  final pepper = hashDetails['lookup_pepper'] as String?;
  final algorithms =
      (hashDetails['algorithms'] as List?)?.cast<String>() ?? [];
  if (pepper == null || !algorithms.contains('sha256')) return {};

  // 5. Build (hash → lowercase address + medium) map
  final hashToAddress = <String, ({String address, String medium})>{};

  void addEntry(String address, String medium) {
    final lower = address.toLowerCase();
    final input = '$lower $medium $pepper';
    final digest = sha256.convert(utf8.encode(input));
    final hash = base64Url.encode(digest.bytes).replaceAll('=', '');
    hashToAddress[hash] = (address: lower, medium: medium);
  }

  for (final email in emails) {
    addEntry(email, 'email');
  }
  for (final phone in phones) {
    final normalized = phone.replaceAll(RegExp(r'[^\d]'), '');
    addEntry(normalized, 'msisdn');
  }

  if (hashToAddress.isEmpty) return {};

  // 6. Perform lookup
  final lookupRes = await http.post(
    Uri.parse('$isBaseUrl/_matrix/identity/v2/lookup'),
    headers: {...authHeader, 'Content-Type': 'application/json'},
    body: jsonEncode({
      'addresses': hashToAddress.keys.toList(),
      'algorithm': 'sha256',
      'pepper': pepper,
    }),
  );
  if (lookupRes.statusCode != 200) return {};
  final mappings =
      (jsonDecode(lookupRes.body) as Map<String, dynamic>)['mappings']
          as Map<String, dynamic>? ??
      {};

  // 7. Build result: lowercase(address) → mxid
  final result = <String, String>{};
  for (final entry in mappings.entries) {
    final info = hashToAddress[entry.key];
    if (info != null) {
      result[info.address] = entry.value as String;
    }
  }
  return result;
}
