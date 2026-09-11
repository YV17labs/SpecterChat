import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/chat_session_manager.dart';
import 'package:specterchat/domain/models/conversation.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryMessageRepository messages;
  late InMemoryConversationRepository conversations;
  late FakeLlmService llm;

  setUp(() {
    messages = InMemoryMessageRepository();
    conversations = InMemoryConversationRepository();
    llm = FakeLlmService([]);
  });

  ChatSessionManager manager({int max = 2}) => ChatSessionManager(
    maxActiveSessions: max,
    resolveDeps: () =>
        depsWith(llm: llm, messages: messages, conversations: conversations),
  );

  test('getOrCreate returns the same instance for the same id', () {
    final m = manager();
    expect(identical(m.getOrCreate('a'), m.getOrCreate('a')), isTrue);
    expect(m.sessionCount, 1);
  });

  test('hydrates prompt tokens from the conversation row', () async {
    conversations.rows['a'] = Conversation(
      id: 'a',
      title: 't',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      lastPromptTokens: 99,
    );
    final s = manager().getOrCreate('a');
    await Future<void>.delayed(Duration.zero);
    expect(s.state.value.promptTokens, 99);
  });

  test('evicts the least recently active idle session over the cap', () async {
    final m = manager();
    final a = m.getOrCreate('a')..lastActivity = DateTime(2020);
    m.getOrCreate('b').lastActivity = DateTime(2021);
    m.getOrCreate('c');
    expect(m.activeConversationIds, unorderedEquals(['b', 'c']));
    // Evicted sessions are disposed: sends are ignored from then on.
    await a.sendMessage('hi');
    expect(llm.calls, 0);
  });

  test('the session being created is never the one evicted', () {
    final m = manager(max: 1);
    m.getOrCreate('a').lastActivity = DateTime(2020);
    final b = m.getOrCreate('b');
    expect(m.activeConversationIds, ['b']);
    expect(identical(m.getOrCreate('b'), b), isTrue);
  });

  test('observed sessions are never evicted', () {
    final m = manager(max: 1);
    m.getOrCreate('a').lastActivity = DateTime(2020);
    m.acquire('a');
    m.getOrCreate('b');
    expect(m.activeConversationIds, unorderedEquals(['a', 'b']));
    // Releasing the observer lets the next eviction pass reclaim it.
    m.release('a');
    expect(m.activeConversationIds, ['b']);
  });

  test('streaming sessions are never evicted', () async {
    final gate = Completer<void>();
    llm = FakeLlmService([
      (_) async* {
        await gate.future;
        yield const StreamDone();
      },
    ]);
    final m = manager(max: 1);
    final send = m.sendMessage('a', 'hi');
    await Future<void>.delayed(Duration.zero);
    m.getOrCreate('a').lastActivity = DateTime(2020);
    m.getOrCreate('b');
    expect(m.activeConversationIds, unorderedEquals(['a', 'b']));
    gate.complete();
    await send;
  });

  test(
    'disposeSession removes and disposes; unknown ids are a no-op',
    () async {
      final m = manager();
      m.getOrCreate('a');
      await m.disposeSession('a');
      await m.disposeSession('nope');
      expect(m.sessionCount, 0);
    },
  );

  test('disposeAll empties the registry', () async {
    final m = manager(max: 10);
    m.getOrCreate('a');
    m.getOrCreate('b');
    await m.disposeAll();
    expect(m.sessionCount, 0);
  });
}
