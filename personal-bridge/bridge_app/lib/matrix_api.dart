import 'dart:convert';

import 'package:http/http.dart' as http;

const defaultHomeserver = 'https://matrix.tjena.eu';
const defaultGateway = 'https://wap.tjena.eu';
const sessionDeviceName = 'WhatsApp bridge (home)';

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

/// Parsed content of the QR code shown by the tjena app:
/// `tjena-bridge://login?hs=...&gw=...&user=@me:tjena.eu&token=LOGIN_TOKEN`
class PairingLink {
  final String homeserver;
  final String gateway;
  final String? user;
  final String? loginToken;
  PairingLink({required this.homeserver, required this.gateway, this.user, this.loginToken});

  static PairingLink? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'tjena-bridge' || uri.host != 'login') return null;
    final q = uri.queryParameters;
    final hs = q['hs'] ?? defaultHomeserver;
    final gw = q['gw'] ?? defaultGateway;
    if (!_isHttpUrl(hs) || !_isHttpUrl(gw)) return null;
    return PairingLink(homeserver: hs, gateway: gw, user: q['user'], loginToken: q['token']);
  }

  static bool _isHttpUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
  }
}

class MatrixSession {
  final String homeserver;
  final String userId;
  final String accessToken;
  final String deviceId;
  MatrixSession(this.homeserver, this.userId, this.accessToken, this.deviceId);

  Map<String, dynamic> toJson() => {
        'homeserver': homeserver,
        'user_id': userId,
        'access_token': accessToken,
        'device_id': deviceId,
      };

  static MatrixSession fromJson(Map<String, dynamic> j) => MatrixSession(
        j['homeserver'] as String,
        j['user_id'] as String,
        j['access_token'] as String,
        j['device_id'] as String? ?? '',
      );
}

Never _fail(http.Response r) {
  String msg;
  try {
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    msg = (j['error'] ?? j['errcode'] ?? r.body).toString();
  } catch (_) {
    msg = r.body.isEmpty ? 'HTTP ${r.statusCode}' : r.body;
  }
  throw ApiException(msg, r.statusCode);
}

String _trim(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

/// Creates this phone's own Matrix session ("WhatsApp bridge (home)").
Future<MatrixSession> login({
  required String homeserver,
  String? loginToken,
  String? user,
  String? password,
}) async {
  final hs = _trim(homeserver);
  final body = loginToken != null
      ? {'type': 'm.login.token', 'token': loginToken}
      : {
          'type': 'm.login.password',
          'identifier': {'type': 'm.id.user', 'user': user},
          'password': password,
        };
  body['initial_device_display_name'] = sessionDeviceName;
  final r = await http
      .post(Uri.parse('$hs/_matrix/client/v3/login'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
      .timeout(const Duration(seconds: 30));
  if (r.statusCode != 200) _fail(r);
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  return MatrixSession(hs, j['user_id'] as String, j['access_token'] as String, j['device_id'] as String? ?? '');
}

Future<void> logout(MatrixSession s) async {
  try {
    await http.post(Uri.parse('${s.homeserver}/_matrix/client/v3/logout'),
        headers: {'Authorization': 'Bearer ${s.accessToken}'}).timeout(const Duration(seconds: 15));
  } catch (_) {}
}

/// Provisioner on the gateway (wap.tjena.eu/provision/v1).
class Provisioner {
  final String gateway;
  final String accessToken;
  Provisioner(String gateway, this.accessToken) : gateway = _trim(gateway);

  Map<String, String> get _h => {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'};

  /// Assigns a bridge slot (or rotates tokens of the existing one).
  Future<Map<String, dynamic>> claim() async {
    final r = await http
        .post(Uri.parse('$gateway/provision/v1/bridge'), headers: _h, body: '{}')
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) _fail(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Status of the user's bridge, or null if they have none.
  Future<Map<String, dynamic>?> status() async {
    final r = await http.get(Uri.parse('$gateway/provision/v1/bridge'), headers: _h).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> revoke() async {
    final r = await http.delete(Uri.parse('$gateway/provision/v1/bridge'), headers: _h).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200 && r.statusCode != 404) _fail(r);
  }
}
