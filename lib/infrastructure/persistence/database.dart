import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

final _log = Logger('AppDatabase');

/// The schema this build knows. Also read before the database is opened
/// ([prepareDatabaseFile]), so it lives outside the class.
const int kSchemaVersion = 10;

class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get systemPrompt => text().nullable()();
  TextColumn get settings => text().nullable()();
  IntColumn get lastPromptTokens => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get role => text()();
  TextColumn get content => text()(); // JSON-encoded List<ContentBlock>
  IntColumn get completionTokens => integer().withDefault(const Constant(0))();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get isStreaming => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// JSON-encoded `MessageStats`: what was measured while the message was
  /// produced, and with what. Written once, never recomputed.
  TextColumn get stats => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// What text requests carried besides their messages (`RequestContext`,
/// JSON): the system prompt as sent and the tool definitions. One row per
/// change within a conversation, referenced by
/// `GenerationStats.requestContextId`; deleted with the conversation.
/// The id is the fingerprint of the content, so storing the same context
/// twice stores it once — per conversation, so a delete cascades cleanly.
@DataClassName('RequestContextRow')
class RequestContexts extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {conversationId, id};
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

/// Schema, migrations and connection — nothing else. Queries live in the
/// repositories so each table has exactly one owner.
@DriftDatabase(tables: [Conversations, Messages, Attachments, RequestContexts])
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
  // v9 — `stats` JSON column on messages (model, settings, timings, server
  //      report of each turn). First step that keeps the user's data.
  // v10 — `request_contexts` table: system prompt as sent and tool
  //       definitions, once per change in a conversation.
  // ---------------------------------------------------------------

  @override
  int get schemaVersion => kSchemaVersion;

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
      if (from < 8) {
        // Fresh slate below v8: drop any pre-UUIDv7 data so `ORDER BY id`
        // is trustworthy. `deleteTable` empties and drops in one step;
        // `createAll` then builds the current schema directly.
        await m.deleteTable(messages.actualTableName);
        await m.deleteTable(conversations.actualTableName);
        if (from >= 7) {
          await m.deleteTable(attachments.actualTableName);
        }
        await m.createAll();
        await customStatement(_createConversationIdIndex);
        await customStatement(_createAttachmentMessageIdIndex);
        return;
      }
      // From v8 on, every step keeps the data.
      if (from < 9) {
        await m.addColumn(messages, messages.stats);
      }
      if (from < 10) {
        await m.createTable(requestContexts);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // Reset any `is_streaming = 1` rows left over from a prior session
      // that crashed or was killed mid-stream. Keeps whatever partial
      // content was already persisted so the user still sees it.
      await customStatement(
        'UPDATE messages SET is_streaming = 0 WHERE is_streaming = 1',
      );
    },
  );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'specterchat', 'specter.db'));
    await file.parent.create(recursive: true);
    await prepareDatabaseFile(file);
    return NativeDatabase.createInBackground(file);
  });
}

/// Guards [file] against the build that is about to open it.
///
/// A file this build would migrate is copied first, next to itself
/// (`specter.db.v9.backup`), so a migration that goes wrong leaves the
/// history untouched somewhere. A file written by a *later* build is set
/// aside instead (`specter.db.v11.newer`) and the app starts on a fresh
/// one: a build that knows less than the file must never rewrite it.
/// Drift runs `onUpgrade` whenever the versions differ, in either
/// direction, and every build up to 0.7.3 recreated its tables there —
/// opening a newer database with one of those empties it.
Future<void> prepareDatabaseFile(
  File file, {
  int version = kSchemaVersion,
}) async {
  final stored = await databaseFileVersion(file);
  if (stored == 0 || stored == version) return;
  if (stored < version) {
    final backup = File('${file.path}.v$stored.backup');
    if (!backup.existsSync()) {
      await file.copy(backup.path);
      _log.info('Upgrading from schema v$stored; kept ${backup.path}');
    }
    return;
  }
  final aside = File('${file.path}.v$stored.newer');
  await file.rename(aside.path);
  _log.severe(
    'Database is schema v$stored, this build knows v$version: '
    'left it at ${aside.path} and started a new one',
  );
}

/// The `user_version` SQLite keeps in a file's header (four bytes at
/// offset 60), or 0 when there is no readable header — a missing file, or
/// one no database wrote yet.
Future<int> databaseFileVersion(File file) async {
  if (!file.existsSync()) return 0;
  final handle = await file.open();
  try {
    await handle.setPosition(60);
    final bytes = await handle.read(4);
    if (bytes.length < 4) return 0;
    return bytes.buffer.asByteData(bytes.offsetInBytes).getUint32(0);
  } finally {
    await handle.close();
  }
}
