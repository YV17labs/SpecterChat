import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/database/database.dart';

import 'generated_migrations/schema.dart';
import 'generated_migrations/schema_v1.dart' as v1;

/// These tests verify that every schema version with a snapshot can be
/// created from scratch and upgraded to the current version, preserving
/// data along the way.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('Schema migration', () {
    test('v1 to current upgrades and validates schema', () async {
      final connection = await verifier.startAt(1);
      final db = AppDatabase.forTesting(connection);
      await verifier.migrateAndValidate(db, db.schemaVersion);
      await db.close();
    });

    test('v2 to current upgrades and validates schema', () async {
      final connection = await verifier.startAt(2);
      final db = AppDatabase.forTesting(connection);
      await verifier.migrateAndValidate(db, db.schemaVersion);
      await db.close();
    });
  });

  group('Data preservation during migration', () {
    test('v1 data survives upgrade to current schema', () async {
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
              content: '[{"runtimeType":"text","text":"preserved"}]',
              createdAt: epoch,
            ),
          );

      await oldDb.close();

      // Open with AppDatabase — triggers the full v1 → current migration.
      final db = AppDatabase.forTesting(schema.newConnection());

      final conversations = await db.getAllConversations();
      expect(conversations, hasLength(1));
      expect(conversations.first.title, 'Pre-migration chat');

      final messages = await db.getMessagesForConversation('old-conv');
      expect(messages, hasLength(1));
      expect(messages.first.content, contains('preserved'));

      // Verify the v2 index was created along the way.
      final indexResult = await db.customSelect(
        'SELECT name FROM sqlite_master '
        "WHERE type = 'index' AND name = 'idx_messages_conversation_id'",
      ).getSingle();
      expect(indexResult.data['name'], 'idx_messages_conversation_id');

      await db.close();
    });
  });
}
