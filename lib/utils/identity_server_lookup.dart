// SPDX-FileCopyrightText: 2024-Present Niklas Hahn
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

class IdentityServerLookupResult {
  final String address;
  final String medium; // 'email' or 'msisdn'
  final String mxid;

  const IdentityServerLookupResult({
    required this.address,
    required this.medium,
    required this.mxid,
  });
}

/// Looks up a list of email/phone addresses against the homeserver's identity
/// server using the IS v2 hashed lookup API (MSC2134).
///
/// Returns a map of address → mxid for all addresses that have a Matrix account.
Future<Map<String, String>> lookupAddressesOnIS(
  Client client,
  List<String> emails,
  List<String> phones,
) async {
  final wellKnown = await client.getWellknown();
  final isBaseUrl = wellKnown.mIdentityServer?.baseUrl;
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
      (jsonDecode(registerRes.body) as Map<String, dynamic>)['token'] as String?;
  if (isToken == null) return {};

  // 3. Get hashing parameters
  final hashDetailsRes = await http.get(
    Uri.parse('$isBaseUrl/_matrix/identity/v2/hash_details'),
    headers: {'Authorization': 'Bearer $isToken'},
  );
  if (hashDetailsRes.statusCode != 200) return {};
  final hashDetails =
      jsonDecode(hashDetailsRes.body) as Map<String, dynamic>;
  final pepper = hashDetails['lookup_pepper'] as String?;
  final algorithms = (hashDetails['algorithms'] as List?)?.cast<String>() ?? [];
  if (pepper == null || !algorithms.contains('sha256')) return {};

  // 4. Build (hash → original address+medium) map
  final hashToAddress = <String, ({String address, String medium})>{};

  void addEntry(String address, String medium) {
    final input = '${address.toLowerCase()} $medium $pepper';
    final digest = sha256.convert(utf8.encode(input));
    final hash = base64Url.encode(digest.bytes).replaceAll('=', '');
    hashToAddress[hash] = (address: address, medium: medium);
  }

  for (final email in emails) {
    addEntry(email, 'email');
  }
  for (final phone in phones) {
    // IS expects E.164 without leading + for msisdn
    final normalized = phone.replaceAll(RegExp(r'[^\d]'), '');
    addEntry(normalized, 'msisdn');
  }

  if (hashToAddress.isEmpty) return {};

  // 5. Perform lookup
  final lookupRes = await http.post(
    Uri.parse('$isBaseUrl/_matrix/identity/v2/lookup'),
    headers: {
      'Authorization': 'Bearer $isToken',
      'Content-Type': 'application/json',
    },
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

  // 6. Build result: original address → mxid
  final result = <String, String>{};
  for (final entry in mappings.entries) {
    final info = hashToAddress[entry.key];
    if (info != null) {
      result[info.address] = entry.value as String;
    }
  }
  return result;
}
