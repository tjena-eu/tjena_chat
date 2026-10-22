import 'package:flutter_test/flutter_test.dart';
import 'package:tjena_bridge/matrix_api.dart';

void main() {
  test('parses the tjena app QR link', () {
    final l = PairingLink.parse(
      'tjena-bridge://login?hs=https%3A%2F%2Fmatrix.tjena.eu&gw=https%3A%2F%2Fwap.tjena.eu&user=%40nik%3Atjena.eu&token=abc123',
    )!;
    expect(l.homeserver, 'https://matrix.tjena.eu');
    expect(l.gateway, 'https://wap.tjena.eu');
    expect(l.user, '@nik:tjena.eu');
    expect(l.loginToken, 'abc123');
  });

  test('rejects other QR codes and non-http URLs', () {
    expect(PairingLink.parse('https://matrix.to/#/@a:b'), isNull);
    expect(PairingLink.parse('tjena-bridge://login?hs=javascript:alert(1)'), isNull);
  });

  test('defaults without token', () {
    final l = PairingLink.parse('tjena-bridge://login?user=%40nik%3Atjena.eu')!;
    expect(l.loginToken, isNull);
    expect(l.gateway, defaultGateway);
  });
}
