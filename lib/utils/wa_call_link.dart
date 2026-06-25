// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:fluffychat/config/setting_keys.dart';

/// Result of provisioning a guest call: the temporary Matrix call room id the
/// host is force-joined into, and the shareable web link for the guest.
class CallLink {
  final String callRoomId;
  final String link;
  const CallLink({required this.callRoomId, required this.link});
}

/// Pings the call-provisioner backend's /healthz to check whether the WhatsApp
/// call feature is online. Returns true on a 2xx response.
Future<bool> callFeatureOnline() async {
  final base = AppSettings.callProvisionerBaseUrl.value.trim();
  if (base.isEmpty) return false;
  try {
    final uri = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/healthz');
    final res = await http.get(uri).timeout(const Duration(seconds: 6));
    return res.statusCode >= 200 && res.statusCode < 300;
  } catch (_) {
    return false;
  }
}

/// Asks the call-provisioner backend to mint an ephemeral guest user + an
/// unencrypted call room, force-join the current user (host), and return a
/// shareable web link. Authenticated with the host's Matrix access token; the
/// backend validates it via /account/whoami and force-joins that user.
///
/// Throws on failure.
Future<CallLink> requestCallLink(Client client) async {
  final base = AppSettings.callProvisionerBaseUrl.value.trim();
  if (base.isEmpty) {
    throw Exception('Call provisioner URL is not configured');
  }
  final token = client.accessToken;
  if (token == null) {
    throw Exception('Not logged in');
  }
  final uri = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/api/calls');
  final res = await http.post(
    uri,
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    },
    body: jsonEncode({'user_id': client.userID}),
  );
  if (res.statusCode != 200) {
    throw Exception('Provisioner returned ${res.statusCode}: ${res.body}');
  }
  final json = jsonDecode(res.body) as Map<String, dynamic>;
  final link = json['link'] as String?;
  final callRoomId = json['callId'] as String? ?? json['room'] as String?;
  if (link == null || link.isEmpty || callRoomId == null) {
    throw Exception('Provisioner returned an invalid response');
  }
  return CallLink(callRoomId: callRoomId, link: link);
}
