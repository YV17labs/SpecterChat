import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/conversation.dart';
import 'package:specterchat/domain/models/conversation_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/infrastructure/persistence/conversation_repository.dart';
import 'package:specterchat/infrastructure/persistence/database.dart'
    hide Conversation, Message;
import 'package:specterchat/infrastructure/persistence/message_repository.dart';

void main() {
  late AppDatabase db;
  late ConversationRepository repo;
  late MessageRepository messages;
  // Drift stores DateTime with one-second precision, so tests drive the
  // clock instead of sleeping.
  var now = DateTime(2024, 1, 1, 12);

  setUp(() {
    now = DateTime(2024, 1, 1, 12);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ConversationRepository(db, now: () => now);
    messages = MessageRepository(db, now: () => now);
  });

  tearDown(() => db.close());

  Future<List<Conversation>> all() => repo.watchAllConversations().first;

  test('createConversation returns an id and uses the default title', () async {
    final id = await repo.createConversation(systemPrompt: 'Be concise');
    final conv = (await all()).single;
    expect(conv.id, id);
    expect(conv.title, kDefaultConversationTitle);
    expect(conv.systemPrompt, 'Be concise');
    expect(conv.lastPromptTokens, 0);
  });

  test('getConversation returns null for unknown ids', () async {
    expect(await repo.getConversation('nope'), isNull);
  });

  test('settings JSON round-trips; corrupted JSON degrades to null', () async {
    const settings = ConversationSettings(contextLength: 123);
    final id = await repo.createConversation(settings: settings);
    expect((await repo.getConversation(id))!.settings, settings);

    await repo.updateConversationSettings(id, null);
    expect((await repo.getConversation(id))!.settings, isNull);

    await db.customUpdate(
      "UPDATE conversations SET settings = '{not json' WHERE id = '$id'",
      updates: {db.conversations},
    );
    expect((await repo.getConversation(id))!.settings, isNull);
  });

  test('renameConversation updates title and bumps updatedAt', () async {
    final id = await repo.createConversation();
    now = now.add(const Duration(minutes: 1));
    await repo.renameConversation(id, 'My Chat');
    final after = (await repo.getConversation(id))!;
    expect(after.title, 'My Chat');
    expect(after.updatedAt, now);
  });

  test('updateLastPromptTokens persists the count', () async {
    final id = await repo.createConversation();
    await repo.updateLastPromptTokens(id, 512);
    expect((await repo.getConversation(id))!.lastPromptTokens, 512);
  });

  test('conversations are ordered by updatedAt desc, then newest id', () async {
    final older = await repo.createConversation();
    final newer = await repo.createConversation();
    // Same second → same updated_at: the UUIDv7 id breaks the tie.
    expect((await all()).map((c) => c.id), [newer, older]);

    now = now.add(const Duration(minutes: 1));
    await repo.renameConversation(older, 'touched');
    expect((await all()).map((c) => c.id), [older, newer]);
  });

  test('watchAllConversations emits on changes', () async {
    final emissions = <int>[];
    final sub = repo.watchAllConversations().listen(
      (l) => emissions.add(l.length),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await repo.createConversation();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    expect(emissions, [0, 1]);
  });

  test('deleteConversation also removes its messages', () async {
    final id = await repo.createConversation();
    await messages.saveMessage(
      Message(
        id: 'msg-1',
        conversationId: id,
        role: MessageRole.user,
        content: [const ContentBlock.text(text: 'hello')],
        createdAt: DateTime.now(),
      ),
    );
    await repo.deleteConversation(id);
    expect(await all(), isEmpty);
    expect(await messages.getMessages(id), isEmpty);
  });
}
