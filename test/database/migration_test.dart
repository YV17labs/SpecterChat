import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/database/database.dart';

import 'generated_migrations/schema.dart';
import 'generated_migrations/schema_v1.dart' as v1;

/// These tests verify that every schema version can be created from scratch
/// and that upgrading from one version to the next produces a valid database.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('Schema migration', () {
    test('v1 to v2 upgrades and validates schema', () async {
      // Start with a v1 database, run migration, verify resulting schema.
      final connection = await verifier.startAt(1);
      final db = AppDatabase.forTesting(connection);
      await verifier.migrateAndValidate(db, 2);
      await db.close();
    });
  });

  group('Data preservation during migration', () {
    test('v1 data survives upgrade to v2', () async {
      // 1. Create a v1 database and insert data using the v1 schema.
      final schema = await verifier.schemaAt(1);
      final oldDb = v1.DatabaseAtV1(schema.newConnection());

      final epoch = DateTime(2024, 1, 1).millisecondsSinceEpoch ~/ 1000;

      await oldDb.into(oldDb.conversations).insert(v1.ConversationsCompanion.insert(
        id: 'old-conv',
        title: 'Pre-migration chat',
        createdAt: epoch,
        updatedAt: epoch,
      ));

      await oldDb.into(oldDb.messages).insert(v1.MessagesCompanion.insert(
        id: 'old-msg',
        conversationId: 'old-conv',
        role: 'assistant',
        content: '[{"runtimeType":"text","text":"preserved"}]',
        createdAt: epoch,
      ));

      await oldDb.close();

      // 2. Open with the real AppDatabase (triggers v1→v2 migration).
      final db = AppDatabase.forTesting(schema.newConnection());

      // 3. Verify data survived the migration.
      final conversations = await db.getAllConversations();
      expect(conversations, hasLength(1));
      expect(conversations.first.title, 'Pre-migration chat');

      final messages = await db.getMessagesForConversation('old-conv');
      expect(messages, hasLength(1));
      expect(messages.first.content, contains('preserved'));

      // 4. Verify the index was created.
      final indexResult = await db.customSelect(
        'SELECT name FROM sqlite_master '
        "WHERE type = 'index' AND name = 'idx_messages_conversation_id'",
      ).getSingle();
      expect(indexResult.data['name'], 'idx_messages_conversation_id');

      await db.close();
    });
  });
}
