import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/database/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('Conversations', () {
    test('insert and retrieve', () async {
      final now = DateTime.now();
      await db.insertConversation(ConversationsCompanion.insert(
        id: 'conv-1',
        title: 'Test Chat',
        createdAt: now,
        updatedAt: now,
      ));

      final all = await db.getAllConversations();
      expect(all.length, 1);
      expect(all.first.id, 'conv-1');
      expect(all.first.title, 'Test Chat');
    });

    test('watchAllConversations emits updates', () async {
      final now = DateTime.now();

      await db.insertConversation(ConversationsCompanion.insert(
        id: 'conv-1',
        title: 'Chat',
        createdAt: now,
        updatedAt: now,
      ));

      // Verify the stream contains the inserted conversation.
      final conversations = await db.watchAllConversations().first;
      expect(conversations, hasLength(1));
      expect(conversations.first.id, 'conv-1');
    });

    test('update conversation', () async {
      final now = DateTime.now();
      await db.insertConversation(ConversationsCompanion.insert(
        id: 'conv-1',
        title: 'Old',
        createdAt: now,
        updatedAt: now,
      ));

      await db.updateConversation(ConversationsCompanion(
        id: const Value('conv-1'),
        title: const Value('New Title'),
        updatedAt: Value(DateTime.now()),
      ));

      final conv = await db.getConversation('conv-1');
      expect(conv.title, 'New Title');
    });

    test('delete conversation', () async {
      final now = DateTime.now();
      await db.insertConversation(ConversationsCompanion.insert(
        id: 'conv-1',
        title: 'Chat',
        createdAt: now,
        updatedAt: now,
      ));

      await db.deleteConversation('conv-1');
      final all = await db.getAllConversations();
      expect(all, isEmpty);
    });

    test('search conversations by title', () async {
      final now = DateTime.now();
      await db.insertConversation(ConversationsCompanion.insert(
        id: 'c-1',
        title: 'Flutter Development',
        createdAt: now,
        updatedAt: now,
      ));
      await db.insertConversation(ConversationsCompanion.insert(
        id: 'c-2',
        title: 'Dart Testing',
        createdAt: now,
        updatedAt: now,
      ));

      final results = await db.searchConversations('Flutter');
      expect(results.length, 1);
      expect(results.first.title, 'Flutter Development');
    });

    test('conversations ordered by updatedAt desc', () async {
      final old = DateTime(2024, 1, 1);
      final recent = DateTime(2024, 6, 1);

      await db.insertConversation(ConversationsCompanion.insert(
        id: 'c-old',
        title: 'Old Chat',
        createdAt: old,
        updatedAt: old,
      ));
      await db.insertConversation(ConversationsCompanion.insert(
        id: 'c-new',
        title: 'New Chat',
        createdAt: recent,
        updatedAt: recent,
      ));

      final all = await db.getAllConversations();
      expect(all.first.id, 'c-new');
      expect(all.last.id, 'c-old');
    });
  });

  group('Messages', () {
    setUp(() async {
      final now = DateTime.now();
      await db.insertConversation(ConversationsCompanion.insert(
        id: 'conv-1',
        title: 'Chat',
        createdAt: now,
        updatedAt: now,
      ));
    });

    test('insert and retrieve messages', () async {
      await db.insertMessage(MessagesCompanion.insert(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: 'user',
        content: '[{"runtimeType":"text","text":"hello"}]',
        createdAt: DateTime.now(),
      ));

      final messages =
          await db.getMessagesForConversation('conv-1');
      expect(messages.length, 1);
      expect(messages.first.id, 'msg-1');
      expect(messages.first.role, 'user');
    });

    test('messages ordered by createdAt', () async {
      final early = DateTime(2024, 1, 1, 10, 0);
      final late_ = DateTime(2024, 1, 1, 10, 5);

      await db.insertMessage(MessagesCompanion.insert(
        id: 'msg-2',
        conversationId: 'conv-1',
        role: 'assistant',
        content: '[{"runtimeType":"text","text":"hi"}]',
        createdAt: late_,
      ));
      await db.insertMessage(MessagesCompanion.insert(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: 'user',
        content: '[{"runtimeType":"text","text":"hello"}]',
        createdAt: early,
      ));

      final messages =
          await db.getMessagesForConversation('conv-1');
      expect(messages.first.id, 'msg-1');
      expect(messages.last.id, 'msg-2');
    });

    test('deleteConversationWithMessages removes both', () async {
      await db.insertMessage(MessagesCompanion.insert(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: 'user',
        content: '[{"runtimeType":"text","text":"hello"}]',
        createdAt: DateTime.now(),
      ));

      await db.deleteConversationWithMessages('conv-1');

      final convs = await db.getAllConversations();
      final msgs = await db.getMessagesForConversation('conv-1');
      expect(convs, isEmpty);
      expect(msgs, isEmpty);
    });

    test('update message content', () async {
      await db.insertMessage(MessagesCompanion.insert(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: 'user',
        content: '[{"runtimeType":"text","text":"old"}]',
        createdAt: DateTime.now(),
      ));

      await db.updateMessage(const MessagesCompanion(
        id: Value('msg-1'),
        content:
            Value('[{"runtimeType":"text","text":"updated"}]'),
      ));

      final messages =
          await db.getMessagesForConversation('conv-1');
      expect(messages.first.content, contains('updated'));
    });

    test('watchRecentMessagesForConversation emits on changes', () async {
      final stream =
          db.watchRecentMessagesForConversation('conv-1', limit: 0);

      expectLater(
        stream,
        emitsInOrder([
          hasLength(0),
          hasLength(1),
        ]),
      );

      await db.insertMessage(MessagesCompanion.insert(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: 'user',
        content: '[{"runtimeType":"text","text":"hi"}]',
        createdAt: DateTime.now(),
      ));
    });
  });

  group('Migration & PRAGMA', () {
    test('foreign_keys pragma is enabled', () async {
      final result =
          await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(result.data['foreign_keys'], 1);
    });

    test('idx_messages_conversation_id index exists', () async {
      final result = await db.customSelect(
        'SELECT name FROM sqlite_master '
        "WHERE type = 'index' AND name = 'idx_messages_conversation_id'",
      ).getSingle();
      expect(result.data['name'], 'idx_messages_conversation_id');
    });

    test('foreign key constraint prevents orphan messages', () async {
      expect(
        () => db.insertMessage(MessagesCompanion.insert(
          id: 'msg-orphan',
          conversationId: 'nonexistent',
          role: 'user',
          content: '[{"runtimeType":"text","text":"hi"}]',
          createdAt: DateTime.now(),
        )),
        throwsA(isA<Exception>()),
      );
    });
  });
}
