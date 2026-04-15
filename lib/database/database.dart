import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get systemPrompt => text().nullable()();
  TextColumn get settings => text().nullable()();
  IntColumn get lastPromptTokens =>
      integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id)();
  TextColumn get role => text()();
  TextColumn get content => text()(); // JSON-encoded List<ContentBlock>
  IntColumn get completionTokens =>
      integer().withDefault(const Constant(0))();
  IntColumn get durationMs =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get isStreaming =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Conversations, Messages])
class AppDatabase extends _$AppDatabase {
  /// Production constructor — uses file-backed SQLite.
  AppDatabase() : super(_openConnection());

  /// Test constructor — accepts any [QueryExecutor] (e.g. in-memory).
  AppDatabase.forTesting(super.executor);

  // ---------------------------------------------------------------
  // Schema version history
  // ---------------------------------------------------------------
  // v1 — Initial schema: conversations + messages tables.
  // v2 — Add index on messages.conversation_id for query performance.
  // v3 — Add completion_tokens + duration_ms columns to messages.
  // v4 — Add settings JSON column to conversations.
  // v5 — Add last_prompt_tokens column to conversations.
  // v6 — Add is_streaming + updated_at columns to messages for
  //      incremental streaming persistence (survives conversation switch
  //      and app restart).
  // ---------------------------------------------------------------

  @override
  int get schemaVersion => 6;

  static const _createConversationIdIndex =
      'CREATE INDEX IF NOT EXISTS idx_messages_conversation_id '
      'ON messages (conversation_id)';

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          await customStatement(_createConversationIdIndex);
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await customStatement(_createConversationIdIndex);
          }
          if (from < 3) {
            await m.addColumn(messages, messages.completionTokens);
            await m.addColumn(messages, messages.durationMs);
          }
          if (from < 4) {
            await m.addColumn(conversations, conversations.settings);
          }
          if (from < 5) {
            await m.addColumn(
                conversations, conversations.lastPromptTokens);
          }
          if (from < 6) {
            await m.addColumn(messages, messages.isStreaming);
            await m.addColumn(messages, messages.updatedAt);
          }
        },
        beforeOpen: (details) async {
          // Enforce foreign-key constraints at runtime.
          await customStatement('PRAGMA foreign_keys = ON');
          // Clear any `is_streaming = 1` rows left over from a prior
          // session that crashed or was killed mid-stream. Whatever
          // partial content had been persisted is kept — we just flip
          // the flag off so the UI stops showing the typing indicator.
          // Safe on freshly-created databases (no rows to update).
          if (details.versionNow >= 6) {
            await customStatement(
                'UPDATE messages SET is_streaming = 0 WHERE is_streaming = 1');
          }
        },
      );

  // --- Conversations ---

  Future<List<Conversation>> getAllConversations() {
    return (select(conversations)
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.updatedAt, mode: OrderingMode.desc)
          ]))
        .get();
  }

  Stream<List<Conversation>> watchAllConversations() {
    return (select(conversations)
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.updatedAt, mode: OrderingMode.desc)
          ]))
        .watch();
  }

  Future<Conversation> getConversation(String id) {
    return (select(conversations)..where((t) => t.id.equals(id)))
        .getSingle();
  }

  Future<int> insertConversation(ConversationsCompanion entry) {
    return into(conversations).insert(entry);
  }

  Future<bool> updateConversation(ConversationsCompanion entry) {
    return (update(conversations)
          ..where((t) => t.id.equals(entry.id.value)))
        .write(entry)
        .then((rows) => rows > 0);
  }

  Future<int> deleteConversation(String id) {
    return (delete(conversations)..where((t) => t.id.equals(id))).go();
  }

  // --- Messages ---

  Future<List<Message>> getMessagesForConversation(String conversationId) {
    return (select(messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy(
              [(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  Stream<List<Message>> watchMessagesForConversation(
      String conversationId) {
    return (select(messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy(
              [(t) => OrderingTerm(expression: t.createdAt)]))
        .watch();
  }

  Future<int> insertMessage(MessagesCompanion entry) {
    return into(messages).insert(entry);
  }

  Future<bool> updateMessage(MessagesCompanion entry) {
    return (update(messages)..where((t) => t.id.equals(entry.id.value)))
        .write(entry)
        .then((rows) => rows > 0);
  }

  /// Upsert a message row. Used for incremental streaming writes: the first
  /// call inserts the placeholder, subsequent calls update content in place.
  Future<void> upsertMessage(MessagesCompanion entry) {
    return into(messages).insertOnConflictUpdate(entry);
  }

  /// Flip `is_streaming` to false for a finished message.
  Future<bool> markMessageFinalized(String id) {
    return (update(messages)..where((t) => t.id.equals(id)))
        .write(MessagesCompanion(
          isStreaming: const Value(false),
          updatedAt: Value(DateTime.now()),
        ))
        .then((rows) => rows > 0);
  }

  /// Reset any `is_streaming = 1` rows left over from a prior session that
  /// crashed or was killed mid-stream. Keeps whatever partial content was
  /// already persisted so the user still sees it.
  Future<int> clearOrphanStreamingFlags() {
    return (update(messages)..where((t) => t.isStreaming.equals(true)))
        .write(const MessagesCompanion(isStreaming: Value(false)));
  }

  /// Delete a message by id — used to drop an empty placeholder when a
  /// stream cancels before any content arrived.
  Future<int> deleteMessage(String id) {
    return (delete(messages)..where((t) => t.id.equals(id))).go();
  }

  Future<int> deleteMessagesForConversation(String conversationId) {
    return (delete(messages)
          ..where((t) => t.conversationId.equals(conversationId)))
        .go();
  }

  Future<void> deleteConversationWithMessages(String id) async {
    await transaction(() async {
      await deleteMessagesForConversation(id);
      await deleteConversation(id);
    });
  }

  Future<List<Conversation>> searchConversations(String query) {
    return (select(conversations)
          ..where((t) => t.title.like('%$query%'))
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.updatedAt, mode: OrderingMode.desc)
          ]))
        .get();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'specterchat', 'specter.db'));
    await file.parent.create(recursive: true);
    return NativeDatabase.createInBackground(file);
  });
}
