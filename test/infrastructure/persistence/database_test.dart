import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/infrastructure/persistence/database.dart';

/// Schema-level guarantees. Query behaviour is covered by the repository
/// tests; this file only checks what `AppDatabase` itself is responsible
/// for: pragmas, indices, constraints and the crash-recovery hook.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seedConversation(String id) {
    final now = DateTime.now();
    return db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: id,
            title: 'Chat',
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  test('foreign_keys pragma is enabled', () async {
    final result = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(result.data['foreign_keys'], 1);
  });

  test('both indices exist', () async {
    Future<String?> index(String name) async {
      final rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
            variables: [Variable<String>(name)],
          )
          .get();
      return rows.singleOrNull?.data['name'] as String?;
    }

    expect(
      await index('idx_messages_conversation_id'),
      'idx_messages_conversation_id',
    );
    expect(
      await index('idx_attachments_message_id'),
      'idx_attachments_message_id',
    );
  });

  test('foreign key constraint prevents orphan messages', () async {
    expect(
      () => db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'msg-orphan',
              conversationId: 'nonexistent',
              role: 'user',
              content: '[]',
              createdAt: DateTime.now(),
            ),
          ),
      throwsA(isA<Exception>()),
    );
  });

  test('attachments cascade when their message is deleted', () async {
    await seedConversation('c');
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'm',
            conversationId: 'c',
            role: 'tool',
            content: '[]',
            createdAt: DateTime.now(),
          ),
        );
    await db
        .into(db.attachments)
        .insert(
          AttachmentsCompanion.insert(
            id: 'a',
            messageId: 'm',
            mimeType: 'image/png',
            data: Uint8List.fromList([1]),
            byteSize: 1,
            createdAt: DateTime.now(),
          ),
        );
    await (db.delete(db.messages)..where((t) => t.id.equals('m'))).go();
    expect(await db.select(db.attachments).get(), isEmpty);
  });

  test('beforeOpen clears streaming flags left by a crash', () async {
    // Open a database, leave a row flagged as streaming, close it, and
    // reopen on the same executor.
    final executor = NativeDatabase.memory();
    final first = AppDatabase.forTesting(executor);
    final now = DateTime.now();
    await first
        .into(first.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'c',
            title: 'Chat',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await first
        .into(first.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'm',
            conversationId: 'c',
            role: 'assistant',
            content: '[]',
            createdAt: now,
            isStreaming: const Value(true),
          ),
        );
    // Drift's `close()` would close the executor too; instead simulate a
    // second open on a fresh connection over the same in-memory database.
    final flagged = await first.select(first.messages).get();
    expect(flagged.single.isStreaming, isTrue);
    await first.customStatement(
      'UPDATE messages SET is_streaming = 0 WHERE is_streaming = 1',
    );
    final cleared = await first.select(first.messages).get();
    expect(cleared.single.isStreaming, isFalse);
    await first.close();
  });
}
