import 'package:fluffychat/utils/personal_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses bridgev2 list-logins reply', () {
    const reply =
        '\n* `491701234567` (+49 170 1234567) - `CONNECTED`\n* `4930123` (Work) - `TRANSIENT_DISCONNECT`';
    final logins = BridgeBotChat.parseLogins(reply);
    expect(logins.length, 2);
    expect(logins[0].id, '491701234567');
    expect(logins[0].state, 'CONNECTED');
    expect(logins[1].state, 'TRANSIENT_DISCONNECT');
  });

  test('no logins', () {
    expect(BridgeBotChat.parseLogins("You're not logged in"), isEmpty);
    expect(BridgeBotChat.parseLogins(null), isEmpty);
  });
}
