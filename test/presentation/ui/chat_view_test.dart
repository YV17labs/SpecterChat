import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/presentation/providers/chat_provider.dart';
import 'package:specterchat/presentation/providers/conversation_provider.dart';
import 'package:specterchat/presentation/ui/chat/chat_view.dart';
import 'package:specterchat/presentation/ui/widgets/message_bubble.dart';

import '../../support/fakes.dart';
import '../../support/pump_app.dart';

void main() {
  testWidgets('shows the empty state when nothing is selected', (tester) async {
    await pumpApp(tester, const ChatView());
    expect(find.text('Select or create a conversation'), findsOneWidget);
  });

  testWidgets('sending a message streams a reply into the list', (
    tester,
  ) async {
    final harness = TestHarness(
      llm: FakeLlmService.events([
        [
          const ContentDelta('Hello '),
          const ContentDelta('back'),
          const StreamDone(),
        ],
      ]),
    );
    final container = await pumpApp(tester, const ChatView(), harness: harness);
    final id = await harness.conversations.createConversation();
    container.read(conversationControllerProvider.notifier).select(id);
    await tester.pumpAndSettle();
    expect(find.text('Start a conversation'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pumpAndSettle();

    final rows = harness.messages.messagesFor(id);
    expect(rows.map((m) => m.role), [MessageRole.user, MessageRole.assistant]);
    expect(rows.last.plainText, 'Hello back');
    expect(find.byType(MessageBubble), findsNWidgets(2));
    // The reply is rendered as markdown, and the conversation was
    // auto-titled from it — so the text shows twice (header + bubble).
    expect(find.text('Hello back'), findsNWidgets(2));
    // Input is cleared and re-enabled after the turn.
    final session = container.read(chatSessionProvider(id));
    expect(session.isGenerating, isFalse);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue, reason: 'enabled=${field.enabled}');
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('Enter sends, Shift+Enter does not', (tester) async {
    final harness = TestHarness(
      llm: FakeLlmService.events([
        [const ContentDelta('ok'), const StreamDone()],
      ]),
    );
    final container = await pumpApp(tester, const ChatView(), harness: harness);
    final id = await harness.conversations.createConversation();
    container.read(conversationControllerProvider.notifier).select(id);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(harness.messages.rows, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      harness.messages.rows.values.map((m) => m.role),
      contains(MessageRole.user),
    );
  });

  testWidgets('an error from the model shows a dismissible banner', (
    tester,
  ) async {
    final harness = TestHarness(
      llm: FakeLlmService.events([
        [const StreamError('server exploded')],
      ]),
    );
    final container = await pumpApp(tester, const ChatView(), harness: harness);
    final id = await harness.conversations.createConversation();
    container.read(conversationControllerProvider.notifier).select(id);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pumpAndSettle();

    expect(find.text('server exploded'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('server exploded'), findsNothing);
  });
}
