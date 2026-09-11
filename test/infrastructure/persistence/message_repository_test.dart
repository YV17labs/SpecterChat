import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/infrastructure/persistence/conversation_repository.dart';
import 'package:specterchat/infrastructure/persistence/database.dart'
    hide Message;
import 'package:specterchat/infrastructure/persistence/message_repository.dart';

import '../../support/fakes.dart';

void main() {
  late AppDatabase db;
  late MessageRepository repo;
  late ConversationRepository conversations;
  late String convId;
  var now = DateTime(2024, 1, 1, 12);

  setUp(() async {
    now = DateTime(2024, 1, 1, 12);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = MessageRepository(db, now: () => now);
    conversations = ConversationRepository(db, now: () => now);
    convId = await conversations.createConversation();
  });

  tearDown(() => db.close());

  Message msg(
    String id, {
    MessageRole role = MessageRole.user,
    List<ContentBlock>? content,
    DateTime? createdAt,
  }) => testMessage(
    role,
    content ?? [ContentBlock.text(text: id)],
    id: id,
    conversationId: convId,
    createdAt: createdAt,
  );

  test('saveMessage and getMessages round-trip every block type', () async {
    final complex = msg(
      'm-1',
      role: MessageRole.assistant,
      content: [
        const ContentBlock.thinking(text: 'thinking...'),
        const ContentBlock.text(text: 'answer'),
        const ContentBlock.toolCall(
          id: 'tc-1',
          name: 'search',
          arguments: '{}',
        ),
        const ContentBlock.toolResult(
          toolCallId: 'tc-1',
          toolName: 'search',
          resultContent: [
            ContentBlock.image(
              attachmentId: 'att-1',
              mimeType: 'image/png',
              byteSize: 123,
            ),
          ],
          rawResponse: '{}',
        ),
      ],
    );
    await repo.saveMessage(complex);
    final loaded = (await repo.getMessages(convId)).single;
    expect(loaded.content, complex.content);
    expect(loaded.role, MessageRole.assistant);
  });

  test('saveMessage bumps the conversation updatedAt', () async {
    now = now.add(const Duration(minutes: 1));
    await repo.saveMessage(msg('m-1'));
    final after = (await conversations.getConversation(convId))!.updatedAt;
    expect(after, now);
  });

  test('messages come back in id order regardless of createdAt', () async {
    await repo.saveMessage(
      msg(
        '01000000-0000-7000-8000-000000000001',
        createdAt: DateTime(2024, 12, 31),
      ),
    );
    await repo.saveMessage(
      msg('02000000-0000-7000-8000-000000000002', createdAt: DateTime(2020)),
    );
    expect((await repo.getMessages(convId)).map((m) => m.id), [
      '01000000-0000-7000-8000-000000000001',
      '02000000-0000-7000-8000-000000000002',
    ]);
  });

  test(
    'watchMessages with a limit returns the most recent window in order',
    () async {
      for (final id in ['a', 'b', 'c', 'd']) {
        await repo.saveMessage(msg(id));
      }
      expect(
        (await repo.watchMessages(convId, limit: 2).first).map((m) => m.id),
        ['c', 'd'],
      );
      expect((await repo.watchMessages(convId).first).map((m) => m.id), [
        'a',
        'b',
        'c',
        'd',
      ]);
    },
  );

  test('watchMessages emits on new messages', () async {
    final emissions = <int>[];
    final sub = repo
        .watchMessages(convId)
        .listen((l) => emissions.add(l.length));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await repo.saveMessage(msg('m-1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    expect(emissions, [0, 1]);
  });

  test('watchMessageCount emits only on count changes', () async {
    final counts = <int>[];
    final sub = repo.watchMessageCount(convId).listen(counts.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await repo.upsertStreamingMessage(msg('s', role: MessageRole.assistant));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await repo.upsertStreamingMessage(msg('s', role: MessageRole.assistant));
    await repo.upsertStreamingMessage(msg('s', role: MessageRole.assistant));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    expect(counts, [0, 1]);
  });

  test(
    'upsertStreamingMessage inserts then updates in place; finalize flips the flag',
    () async {
      await repo.upsertStreamingMessage(
        msg(
          's',
          role: MessageRole.assistant,
          content: [const ContentBlock.text(text: 'par')],
        ),
      );
      await repo.upsertStreamingMessage(
        msg(
          's',
          role: MessageRole.assistant,
          content: [const ContentBlock.text(text: 'partial')],
        ),
      );
      var loaded = (await repo.getMessages(convId)).single;
      expect(loaded.isStreaming, isTrue);
      expect((loaded.content.single as TextContentBlock).text, 'partial');

      await repo.finalizeStreamingMessage('s');
      loaded = (await repo.getMessages(convId)).single;
      expect(loaded.isStreaming, isFalse);
    },
  );

  test('deleteMessage removes the row', () async {
    await repo.saveMessage(msg('m-1'));
    await repo.deleteMessage('m-1');
    expect(await repo.getMessages(convId), isEmpty);
  });

  test('runInTransaction rolls back on error', () async {
    await expectLater(
      repo.runInTransaction(() async {
        await repo.saveMessage(msg('m-1'));
        throw StateError('abort');
      }),
      throwsStateError,
    );
    expect(await repo.getMessages(convId), isEmpty);
  });
}
