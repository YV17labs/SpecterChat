import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/presentation/providers/conversation_provider.dart';
import 'package:specterchat/presentation/ui/sidebar_left/conversation_list.dart';

import '../../support/pump_app.dart';

void main() {
  testWidgets('New Chat creates and selects a conversation', (tester) async {
    final harness = TestHarness();
    final container = await pumpApp(
      tester,
      const ConversationList(),
      harness: harness,
    );
    await tester.pumpAndSettle();
    expect(find.text('No conversations yet'), findsOneWidget);

    await tester.tap(find.byTooltip('New Chat'));
    await tester.pumpAndSettle();

    expect(harness.conversations.rows, hasLength(1));
    expect(
      container.read(conversationControllerProvider),
      harness.conversations.rows.keys.single,
    );
    expect(find.text('New Chat'), findsOneWidget);
  });

  testWidgets('search filters by title, delete asks for confirmation', (
    tester,
  ) async {
    final harness = TestHarness();
    await pumpApp(tester, const ConversationList(), harness: harness);
    final a = await harness.conversations.createConversation();
    final b = await harness.conversations.createConversation();
    await harness.conversations.renameConversation(a, 'Flutter tips');
    await harness.conversations.renameConversation(b, 'Dart tricks');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'flut');
    await tester.pumpAndSettle();
    expect(find.text('Flutter tips'), findsOneWidget);
    expect(find.text('Dart tricks'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Conversation'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(harness.conversations.rows.keys, [b]);
  });
}
