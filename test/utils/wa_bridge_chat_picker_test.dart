import 'package:fluffychat/pages/new_private_chat/wa_bridge_chat_picker.dart';
import 'package:flutter_test/flutter_test.dart';

// Reply strings exactly as mautrix-go v0.32 renders bridgev2's `search` and
// `start-chat` replies (format.RenderMarkdown).
const searchHtml = '''<p>Search results:</p>
<ul>
<li><code>491701234567</code> / <a href="https://matrix.to/#/@wa01_491701234567:tjena.eu">Anna &amp; Co</a> - DM portal: <a href="https://matrix.to/#/%21AbC123:tjena.eu">Anna</a></li>
<li><code>lid-1234</code> / <a href="https://matrix.to/#/@wa01_lid-1234:tjena.eu">Bob</a></li>
</ul>''';
const searchBody = '''Search results:

* `491701234567` / Anna & Co - DM portal: Anna (https://matrix.to/#/!AbC123:tjena.eu)
* `lid-1234` / Bob''';

void main() {
  test('parses search results from HTML', () {
    final r = parseSearchReply(searchHtml, searchBody);
    expect(r.length, 2);
    expect(r[0].id, '491701234567');
    expect(r[0].name, 'Anna & Co');
    expect(r[0].roomId, '!AbC123:tjena.eu');
    expect(r[0].identifier, '+491701234567');
    expect(r[1].id, 'lid-1234');
    expect(r[1].name, 'Bob');
    expect(r[1].roomId, isNull);
    expect(r[1].identifier, 'lid-1234');
  });

  test('parses search results from the plain body', () {
    final r = parseSearchReply(null, searchBody);
    expect(r.length, 2);
    expect(r[0].id, '491701234567');
    expect(r[0].roomId, '!AbC123:tjena.eu');
    expect(r[1].name, 'Bob');
  });

  test('finds the room in a start-chat reply', () {
    const html = 'Created chat with <code>491701234567</code> / '
        '<a href="https://matrix.to/#/@wa01_491701234567:tjena.eu">Anna</a>: '
        '<a href="https://matrix.to/#/%21AbC123:tjena.eu">Anna</a>';
    expect(roomIdFromReply(html, null), '!AbC123:tjena.eu');
    expect(
      roomIdFromReply(null, 'You already have a direct chat with `4917` / Anna at Anna (https://matrix.to/#/!X:y)'),
      '!X:y',
    );
    expect(roomIdFromReply(null, 'Failed to resolve identifier: not on WhatsApp'), isNull);
  });
}
