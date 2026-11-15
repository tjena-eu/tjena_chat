import 'package:fluffychat/pages/new_private_chat/wa_bridge_chat_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const body =
      'Search results:\n\n* `lid-42065060733007` / Chris 🌻 (WA)\n* `lid-181917718716485` / Christian (EMBC-saufi) (WA)\n* `491701234567` / [Eva (WA)](https://matrix.to/#/@wa01_491701234567:tjena.eu) - DM portal: [Eva](https://matrix.to/#/!abc:tjena.eu)';
  const html =
      '<p>Search results:</p>\n<ul>\n<li><code>lid-42065060733007</code> / Chris 🌻 (WA)</li>\n<li><code>lid-181917718716485</code> / Christian (EMBC-saufi) (WA)</li>\n<li><code>491701234567</code> / <a href="https://matrix.to/#/@wa01_491701234567:tjena.eu">Eva (WA)</a> - DM portal: <a href="https://matrix.to/#/!abc:tjena.eu">Eva</a></li>\n</ul>\n';
  for (final (h, b) in [(html, body), (null, body)]) {
    test('parse ${h == null ? 'body' : 'html'}', () {
      final r = parseSearchReply(h, b);
      expect(r.length, 3);
      expect(r[1].displayName, 'Christian (EMBC-saufi)');
      expect(r[0].displayName, 'Chris 🌻');
      expect(r[2].roomId, '!abc:tjena.eu');
    });
  }
}
