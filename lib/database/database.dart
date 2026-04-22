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

/// Binary attachments (images, in practice) referenced by id from a
/// message's content JSON. Keeping bytes out of the JSON column means
/// the messages table stays small — cheap to serialize on every stream
/// upsert — and bytes only live in RAM when explicitly loaded.
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get messageId =>
      text().references(Messages, #id, onDelete: KeyAction.cascade)();
  TextColumn get mimeType => text()();
  BlobColumn get data => blob()();
  IntColumn get byteSize => integer()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Conversations, Messages, Attachments])
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
  // v7 — Attachments table; image bytes leave message content JSON.
  // v8 — Ids standardised to UUIDv7 so `ORDER BY id` is the strict total
  //      order. All row reads/writes rely on this invariant.
  // ---------------------------------------------------------------

  @override
  int get schemaVersion => 8;

  static const _createConversationIdIndex =
      'CREATE INDEX IF NOT EXISTS idx_messages_conversation_id '
      'ON messages (conversation_id)';

  static const _createAttachmentMessageIdIndex =
      'CREATE INDEX IF NOT EXISTS idx_attachments_message_id '
      'ON attachments (message_id)';

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          await customStatement(_createConversationIdIndex);
          await customStatement(_createAttachmentMessageIdIndex);
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // Fresh slate at v8: drop any pre-UUIDv7 data so `ORDER BY id`
          // is trustworthy. FK cascade on `attachments.message_id`
          // handles image blobs automatically.
          await customStatement('DELETE FROM messages');
          await customStatement('DELETE FROM conversations');
          await m.deleteTable(messages.actualTableName);
          await m.deleteTable(conversations.actualTableName);
          if (from >= 7) {
            await m.deleteTable(attachments.actualTableName);
          }
          await m.createAll();
          await customStatement(_createConversationIdIndex);
          await customStatement(_createAttachmentMessageIdIndex);
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement(
              'UPDATE messages SET is_streaming = 0 WHERE is_streaming = 1');
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
          ..orderBy([(t) => OrderingTerm(expression: t.id)]))
        .get();
  }

  /// Watch the most recent [limit] messages for a conversation in
  /// insertion order. UUIDv7 guarantees `ORDER BY id` is a strict total
  /// order equivalent to insertion time — no tie-break tricks needed.
  /// [limit] `<= 0` streams the full history.
  Stream<List<Message>> watchRecentMessagesForConversation(
    String conversationId, {
    required int limit,
  }) {
    if (limit <= 0) {
      return (select(messages)
            ..where((t) => t.conversationId.equals(conversationId))
            ..orderBy([(t) => OrderingTerm(expression: t.id)]))
          .watch();
    }
    return (select(messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows.reversed.toList(growable: false));
  }

  /// Stream of the total number of persisted messages for a conversation.
  /// Emits only when the count actually changes — Drift re-runs the query
  /// on every `messages` table mutation, and `distinct()` filters out
  /// the no-op re-emissions that happen during streaming upserts (where
  /// the row is updated in-place and the count stays the same).
  Stream<int> watchMessageCountForConversation(String conversationId) {
    final countExp = messages.id.count();
    final query = selectOnly(messages)
      ..addColumns([countExp])
      ..where(messages.conversationId.equals(conversationId));
    return query
        .watchSingle()
        .map((row) => row.read(countExp) ?? 0)
        .distinct();
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

  // --- Attachments ---

  Future<int> insertAttachment(AttachmentsCompanion entry) {
    return into(attachments).insert(entry);
  }

  Future<Attachment?> getAttachment(String id) {
    return (select(attachments)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<List<Attachment>> getAttachmentsByIds(Set<String> ids) {
    if (ids.isEmpty) return Future.value(const <Attachment>[]);
    return (select(attachments)..where((t) => t.id.isIn(ids))).get();
  }

  Future<int> deleteAttachmentsForMessage(String messageId) {
    return (delete(attachments)..where((t) => t.messageId.equals(messageId)))
        .go();
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
