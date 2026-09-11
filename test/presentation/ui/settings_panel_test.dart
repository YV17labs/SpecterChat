import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/presentation/providers/conversation_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';
import 'package:specterchat/presentation/ui/sidebar_right/settings_panel.dart';

import '../../support/pump_app.dart';

void main() {
  testWidgets('global mode: edits write to app settings', (tester) async {
    final harness = TestHarness();
    final container = await pumpApp(
      tester,
      const SizedBox(width: 320, child: SettingsPanel()),
      harness: harness,
    );
    await tester.pumpAndSettle();
    expect(find.text('Editing settings for this conversation'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextField, 'http://localhost:1234/v1'),
      'http://example.test/v1',
    );
    expect(
      container.read(settingsProvider).api.baseUrl,
      'http://example.test/v1',
    );

    final prompt = find.widgetWithText(
      TextField,
      'You are a helpful assistant...',
    );
    await tester.scrollUntilVisible(
      prompt,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(prompt, 'Be terse');
    expect(container.read(settingsProvider).defaultSystemPrompt, 'Be terse');
  });

  testWidgets('conversation mode: edits go to the conversation override', (
    tester,
  ) async {
    final harness = TestHarness();
    final container = await pumpApp(
      tester,
      const SizedBox(width: 320, child: SettingsPanel()),
      harness: harness,
    );
    final id = await harness.conversations.createConversation();
    container.read(conversationControllerProvider.notifier).select(id);
    await tester.pumpAndSettle();
    expect(find.text('Editing settings for this conversation'), findsOneWidget);

    final prompt = find.widgetWithText(
      TextField,
      'You are a helpful assistant...',
    );
    await tester.scrollUntilVisible(
      prompt,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(prompt, 'Only for this chat');
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      harness.conversations.rows[id]!.settings!.systemPrompt,
      'Only for this chat',
    );
    expect(container.read(settingsProvider).defaultSystemPrompt, isEmpty);
  });
}
