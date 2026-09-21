import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/message.dart' as model;
import '../../domain/models/photo_metadata.dart' show AiOrigin;
import '../../domain/repositories/i_message_repository.dart';
import 'database.dart';

/// Drift-backed implementation of [IMessageRepository].
///
/// UUIDv7 ids guarantee `ORDER BY id` is a strict total order equivalent
/// to insertion time — no tie-break on `created_at` needed anywhere.
class MessageRepository implements IMessageRepository {
  final AppDatabase _db;
  final DateTime Function() _now;

  /// [now] stamps `updated_at`; injectable for tests.
  MessageRepository(this._db, {DateTime Function() now = DateTime.now})
    : _now = now;

  @override
  Stream<List<model.Message>> watchMessages(
    String conversationId, {
    int? limit,
  }) {
    final query = _db.select(_db.messages)
      ..where((t) => t.conversationId.equals(conversationId));
    if (limit == null || limit <= 0) {
      query.orderBy([(t) => OrderingTerm(expression: t.id)]);
      return query.watch().map(_toModels);
    }
    // Most recent [limit] rows, then flipped back to chronological order.
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.watch().map((rows) => _toModels(rows.reversed));
  }

  @override
  Future<List<model.Message>> getMessages(String conversationId) async {
    final rows =
        await (_db.select(_db.messages)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm(expression: t.id)]))
            .get();
    return _toModels(rows);
  }

  @override
  Stream<int> watchMessageCount(String conversationId) {
    final countExp = _db.messages.id.count();
    final query = _db.selectOnly(_db.messages)
      ..addColumns([countExp])
      ..where(_db.messages.conversationId.equals(conversationId));
    // Drift re-runs the query on every `messages` mutation; `distinct()`
    // drops the no-op re-emissions caused by streaming upserts.
    return query.watchSingle().map((row) => row.read(countExp) ?? 0).distinct();
  }

  @override
  Future<void> saveMessage(model.Message message) {
    return _db.transaction(() async {
      await _db.into(_db.messages).insert(_toCompanion(message));
      await (_db.update(_db.conversations)
            ..where((t) => t.id.equals(message.conversationId)))
          .write(ConversationsCompanion(updatedAt: Value(_now())));
    });
  }

  @override
  Future<void> upsertStreamingMessage(model.Message message) {
    return _db
        .into(_db.messages)
        .insertOnConflictUpdate(
          _toCompanion(
            message,
          ).copyWith(isStreaming: const Value(true), updatedAt: Value(_now())),
        );
  }

  @override
  Future<void> finalizeStreamingMessage(String messageId) async {
    await (_db.update(
      _db.messages,
    )..where((t) => t.id.equals(messageId))).write(
      MessagesCompanion(
        isStreaming: const Value(false),
        updatedAt: Value(_now()),
      ),
    );
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    await (_db.delete(_db.messages)..where((t) => t.id.equals(messageId))).go();
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) {
    return _db.transaction(action);
  }

  static MessagesCompanion _toCompanion(model.Message message) {
    return MessagesCompanion.insert(
      id: message.id,
      conversationId: message.conversationId,
      role: message.role.name,
      content: jsonEncode(message.content.map((c) => c.toJson()).toList()),
      completionTokens: Value(message.completionTokens),
      durationMs: Value(message.durationMs),
      createdAt: message.createdAt,
      isStreaming: Value(message.isStreaming),
    );
  }

  static List<model.Message> _toModels(Iterable<Message> rows) =>
      rows.map(_toModel).toList(growable: false);

  static model.Message _toModel(Message row) {
    final role = model.MessageRole.values.byName(row.role);
    final blocks = (jsonDecode(row.content) as List)
        .map((c) => model.ContentBlock.fromJson(c as Map<String, dynamic>))
        .toList();
    return model.Message(
      id: row.id,
      conversationId: row.conversationId,
      role: role,
      content: role == model.MessageRole.assistant
          ? _withLegacyAiOrigin(blocks)
          : blocks,
      createdAt: row.createdAt,
      completionTokens: row.completionTokens,
      durationMs: row.durationMs,
      isStreaming: row.isStreaming,
    );
  }

  /// Images a model made before their block recorded it have no
  /// [model.ImageContentBlock.aiOrigin]: an image in a reply is the
  /// model's, an edited photo when it inherited a photo's metadata. The one
  /// place the message's role still says how an image was made.
  static List<model.ContentBlock> _withLegacyAiOrigin(
    List<model.ContentBlock> blocks,
  ) => [
    for (final b in blocks)
      if (b case model.ImageContentBlock(aiOrigin: null, :final photoMetadata))
        b.copyWith(
          aiOrigin: photoMetadata == null
              ? AiOrigin.generated
              : AiOrigin.editedPhoto,
        )
      else
        b,
  ];
}
