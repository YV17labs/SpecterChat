import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/presentation/ui/widgets/content_blocks.dart';
import 'package:specterchat/presentation/ui/widgets/message_bubble.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  /// Pumps [child], runs [tap] and returns the links that were opened.
  Future<List<Uri>> openedBy(
    WidgetTester tester,
    Widget child,
    Future<void> Function() tap,
  ) async {
    final h = TestHarness();
    await pumpApp(tester, child, harness: h);
    await tap();
    await tester.pump();
    return h.links.opened;
  }

  Future<void> Function() tapText(WidgetTester tester, String label) =>
      () => tester.tapOnText(find.textRange.ofSubstring(label));

  /// A selectable [TextBlock] is an `EditableText`, which `find.textRange`
  /// does not search: tap its first letter, where these texts put the link.
  Future<void> Function() tapFirstLetter(WidgetTester tester) =>
      () => tester.tapAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(4, 8),
      );

  testWidgets('a link opens in the browser', (tester) async {
    expect(
      await openedBy(
        tester,
        const TextBlock(text: '[The docs](https://example.com/docs) say so.'),
        tapFirstLetter(tester),
      ),
      [Uri.parse('https://example.com/docs')],
    );
  });

  testWidgets('a bare address is a link too', (tester) async {
    expect(
      await openedBy(
        tester,
        const TextBlock(text: 'www.example.com has more'),
        tapFirstLetter(tester),
      ),
      [Uri.parse('http://www.example.com')],
    );
  });

  testWidgets('a link opens while the reply streams', (tester) async {
    expect(
      await openedBy(
        tester,
        const TextBlock(
          text: '[the docs](https://example.com/docs)',
          isStreaming: true,
        ),
        tapText(tester, 'the docs'),
      ),
      [Uri.parse('https://example.com/docs')],
    );
  });

  testWidgets("a link opens inside the reply's selection area", (tester) async {
    expect(
      await openedBy(
        tester,
        MessageBubble(
          message: testMessage(MessageRole.assistant, [
            const ContentBlock.text(
              text: 'Read [the docs](https://example.com).',
            ),
          ]),
          onTellMore: (_) {},
        ),
        tapText(tester, 'the docs'),
      ),
      [Uri.parse('https://example.com')],
    );
  });

  testWidgets('a link to a local file is not opened', (tester) async {
    expect(
      await openedBy(
        tester,
        const TextBlock(text: '[This](file:///etc/passwd) is local.'),
        tapFirstLetter(tester),
      ),
      isEmpty,
    );
  });
}
