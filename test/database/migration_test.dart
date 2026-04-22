import 'package:drift/drift.dart' show Variable;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/database/database.dart';

import 'generated_migrations/schema.dart';
import 'generated_migrations/schema_v1.dart' as v1;

/// Schema migrations always produce a valid v8 database with UUIDv7 ids.
/// The v8 upgrade wipes any pre-v8 rows so the id column never mixes
/// legacy UUIDv4 values with fresh UUIDv7 ones — `ORDER BY id` is the
/// app-wide canonical ordering, and that requires a single id scheme.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('Schema migration', () {
    for (final from in [1, 2]) {
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

      final epoch = DateTime(2024, 1, 1).millisecondsSinceEpoch ~/ 1000;
      await oldDb.into(oldDb.conversations).insert(
            v1.ConversationsCompanion.insert(
              id: 'old-conv',
              title: 'Pre-migration chat',
              createdAt: epoch,
              updatedAt: epoch,
            ),
          );
      await oldDb.into(oldDb.messages).insert(
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

      expect(await db.getAllConversations(), isEmpty);
      expect(
        await db.getMessagesForConversation('old-conv'),
        isEmpty,
      );

      Future<Map<String, Object?>> indexRow(String name) async {
        return (await db.customSelect(
          'SELECT name FROM sqlite_master '
          "WHERE type = 'index' AND name = ?",
          variables: [Variable<String>(name)],
        ).getSingle())
            .data;
      }

      expect((await indexRow('idx_messages_conversation_id'))['name'],
          'idx_messages_conversation_id');
      expect((await indexRow('idx_attachments_message_id'))['name'],
          'idx_attachments_message_id');

      await db.close();
    });
  });
}
