import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/chat_session_manager.dart';
import 'package:specterchat/application/conversations/conversation_actions.dart';
import 'package:specterchat/domain/models/conversation_settings.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryConversationRepository conversations;
  late ChatSessionManager sessions;
  late ConversationActions actions;

  setUp(() {
    conversations = InMemoryConversationRepository();
    sessions = ChatSessionManager(
      resolveDeps: () => depsWith(
        llm: FakeLlmService([]),
        messages: InMemoryMessageRepository(),
        conversations: conversations,
      ),
    );
    actions = ConversationActions(
      conversations: conversations,
      sessions: sessions,
      settingsWriteDebounce: const Duration(milliseconds: 20),
    );
  });

  test('createNew stores the default prompt, or null when empty', () async {
    final a = await actions.createNew(defaultSystemPrompt: 'Be brief');
    final b = await actions.createNew(defaultSystemPrompt: '');
    expect(conversations.rows[a]!.systemPrompt, 'Be brief');
    expect(conversations.rows[b]!.systemPrompt, isNull);
  });

  test('fork inherits prompt and settings but not messages', () async {
    const settings = ConversationSettings(contextLength: 8192);
    final source = await conversations.createConversation(
      systemPrompt: 'P',
      settings: settings,
    );
    final forked = await actions.fork(source);
    expect(forked, isNot(source));
    expect(conversations.rows[forked]!.systemPrompt, 'P');
    expect(conversations.rows[forked]!.settings, settings);
  });

  test('fork of a deleted source falls back to a blank conversation', () async {
    final forked = await actions.fork('missing');
    expect(conversations.rows[forked]!.systemPrompt, isNull);
  });

  group('updateSettings', () {
    const a = ConversationSettings(contextLength: 1);
    const b = ConversationSettings(contextLength: 2);

    test(
      'coalesces successive edits into one write after the debounce',
      () async {
        final id = await conversations.createConversation();
        actions.updateSettings(id, a);
        actions.updateSettings(id, b);
        expect(conversations.rows[id]!.settings, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(conversations.rows[id]!.settings, b);
      },
    );

    test('flushPendingSettings writes immediately', () async {
      final id = await conversations.createConversation();
      actions.updateSettings(id, a);
      await actions.flushPendingSettings();
      expect(conversations.rows[id]!.settings, a);
      // The timer was cancelled: nothing overwrites later.
      actions.updateSettings(id, b);
      await actions.flushPendingSettings();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(conversations.rows[id]!.settings, b);
    });

    test('delete drops a pending edit for that conversation', () async {
      final id = await conversations.createConversation();
      actions.updateSettings(id, a);
      await actions.delete(id);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(conversations.rows, isEmpty);
    });
  });

  test('delete disposes the session before removing the row', () async {
    final id = await conversations.createConversation();
    sessions.getOrCreate(id);
    await actions.delete(id);
    expect(sessions.sessionCount, 0);
    expect(conversations.rows, isEmpty);
  });
}
