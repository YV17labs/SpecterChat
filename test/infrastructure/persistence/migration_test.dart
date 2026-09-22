import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/message_stats.dart';
import 'package:specterchat/infrastructure/persistence/conversation_repository.dart';
import 'package:specterchat/infrastructure/persistence/database.dart';
import 'package:specterchat/infrastructure/persistence/message_repository.dart';

import 'generated_migrations/schema.dart';
import 'generated_migrations/schema_v1.dart' as v1;
import 'generated_migrations/schema_v8.dart' as v8;
import 'generated_migrations/schema_v9.dart' as v9;

/// Schema migrations always produce a valid current database with UUIDv7
/// ids. Coming from below v8 wipes the rows so the id column never mixes
/// legacy UUIDv4 values with fresh UUIDv7 ones — `ORDER BY id` is the
/// app-wide canonical ordering, and that requires a single id scheme.
/// From v8 on, every step keeps the user's data.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('Schema migration', () {
    for (final from in [1, 2, 6, 7, 8, 9]) {
      test('v$from → current validates schema', () async {
        final connection = await verifier.startAt(from);
        final db = AppDatabase.forTesting(connection);
        await verifier.migrateAndValidate(db, db.schemaVersion);
        await db.close();
      });
    }
  });

  group('v8 upgrade wipes pre-v8 data', () {
    test('v1 rows are removed and indices are re-created', () async {
      final schema = await verifier.schemaAt(1);
      final oldDb = v1.DatabaseAtV1(schema.newConnection());

      final epoch = DateTime(2024).millisecondsSinceEpoch ~/ 1000;
      await oldDb
          .into(oldDb.conversations)
          .insert(
            v1.ConversationsCompanion.insert(
              id: 'old-conv',
              title: 'Pre-migration chat',
              createdAt: epoch,
              updatedAt: epoch,
            ),
          );
      await oldDb
          .into(oldDb.messages)
          .insert(
            v1.MessagesCompanion.insert(
              id: 'old-msg',
              conversationId: 'old-conv',
              role: 'assistant',
              content: '[{"runtimeType":"text","text":"dropped"}]',
              createdAt: epoch,
            ),
          );
      await oldDb.close();

      final db = AppDatabase.forTesting(schema.newConnection());

      expect(await db.select(db.conversations).get(), isEmpty);
      expect(await db.select(db.messages).get(), isEmpty);

      Future<Map<String, Object?>> indexRow(String name) async {
        return (await db
                .customSelect(
                  'SELECT name FROM sqlite_master '
                  "WHERE type = 'index' AND name = ?",
                  variables: [Variable<String>(name)],
                )
                .getSingle())
            .data;
      }

      expect(
        (await indexRow('idx_messages_conversation_id'))['name'],
        'idx_messages_conversation_id',
      );
      expect(
        (await indexRow('idx_attachments_message_id'))['name'],
        'idx_attachments_message_id',
      );

      await db.close();
    });
  });

  group('v10 upgrade keeps v9 data', () {
    test('stats survive, request contexts start empty', () async {
      final schema = await verifier.schemaAt(9);
      final oldDb = v9.DatabaseAtV9(schema.newConnection());
      final epoch = DateTime(2026).millisecondsSinceEpoch ~/ 1000;
      await oldDb
          .into(oldDb.conversations)
          .insert(
            v9.ConversationsCompanion.insert(
              id: 'conv',
              title: 'Kept chat',
              createdAt: epoch,
              updatedAt: epoch,
            ),
          );
      const stats =
          '{"runtimeType":"generation","model":"qwen3",'
          '"startedAt":"2026-09-22T10:00:00.000Z","durationMs":1500,'
          '"outcome":"completed"}';
      await oldDb
          .into(oldDb.messages)
          .insert(
            v9.MessagesCompanion.insert(
              id: 'msg',
              conversationId: 'conv',
              role: 'assistant',
              content: '[{"runtimeType":"text","text":"still here"}]',
              durationMs: const Value(1500),
              createdAt: epoch,
              stats: const Value(stats),
            ),
          );
      await oldDb.close();

      final db = AppDatabase.forTesting(schema.newConnection());
      final message = (await MessageRepository(db).getMessages('conv')).single;
      expect(message.plainText, 'still here');
      expect((message.stats! as GenerationStats).model, 'qwen3');
      expect(
        await ConversationRepository(db).getRequestContexts('conv'),
        isEmpty,
      );
      await db.close();
    });
  });

  group('v9 upgrade keeps v8 data', () {
    test(
      'conversations, messages and attachments survive, stats empty',
      () async {
        final schema = await verifier.schemaAt(8);
        final oldDb = v8.DatabaseAtV8(schema.newConnection());
        final epoch = DateTime(2026).millisecondsSinceEpoch ~/ 1000;
        await oldDb
            .into(oldDb.conversations)
            .insert(
              v8.ConversationsCompanion.insert(
                id: 'conv',
                title: 'Kept chat',
                createdAt: epoch,
                updatedAt: epoch,
              ),
            );
        await oldDb
            .into(oldDb.messages)
            .insert(
              v8.MessagesCompanion.insert(
                id: 'msg',
                conversationId: 'conv',
                role: 'assistant',
                content: '[{"runtimeType":"text","text":"still here"}]',
                completionTokens: const Value(354),
                durationMs: const Value(15700),
                createdAt: epoch,
              ),
            );
        await oldDb
            .into(oldDb.attachments)
            .insert(
              v8.AttachmentsCompanion.insert(
                id: 'att',
                messageId: 'msg',
                mimeType: 'image/png',
                data: Uint8List.fromList([1, 2, 3]),
                byteSize: 3,
                createdAt: epoch,
              ),
            );
        await oldDb.close();

        final db = AppDatabase.forTesting(schema.newConnection());
        final messages = await MessageRepository(db).getMessages('conv');

        expect(
          (await db.select(db.conversations).getSingle()).title,
          'Kept chat',
        );
        expect(messages.single.content, [
          const ContentBlock.text(text: 'still here'),
        ]);
        expect(messages.single.completionTokens, 354);
        expect(messages.single.durationMs, 15700);
        expect(messages.single.stats, isNull);
        expect(await db.select(db.attachments).get(), hasLength(1));
        await db.close();
      },
    );
  });
}
