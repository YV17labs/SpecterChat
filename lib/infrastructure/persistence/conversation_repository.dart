import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../core/id_gen.dart';
import '../../domain/models/conversation.dart' as model;
import '../../domain/models/conversation_settings.dart';
import '../../domain/repositories/i_conversation_repository.dart';
import 'database.dart';

final _log = Logger('ConversationRepository');

/// Drift-backed implementation of [IConversationRepository].
class ConversationRepository implements IConversationRepository {
  final AppDatabase _db;
  final DateTime Function() _now;

  /// [now] is the clock used for `created_at` / `updated_at` stamps —
  /// injectable so tests can control recency without sleeping.
  ConversationRepository(this._db, {DateTime Function() now = DateTime.now})
    : _now = now;

  /// Most recently touched first. `updated_at` has one-second precision in
  /// SQLite, so ties are broken by id (UUIDv7 — creation order).
  SimpleSelectStatement<$ConversationsTable, Conversation> _byRecency() =>
      _db.select(_db.conversations)..orderBy([
        (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ]);

  @override
  Stream<List<model.Conversation>> watchAllConversations() {
    return _byRecency().watch().map(
      (rows) => rows.map(_toModel).toList(growable: false),
    );
  }

  @override
  Future<model.Conversation?> getConversation(String id) async {
    final row = await (_db.select(
      _db.conversations,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<String> createConversation({
    String? systemPrompt,
    ConversationSettings? settings,
  }) async {
    final id = generateId();
    final now = _now();
    await _db
        .into(_db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: id,
            title: model.kDefaultConversationTitle,
            createdAt: now,
            updatedAt: now,
            systemPrompt: Value(systemPrompt),
            settings: Value(_encodeSettings(settings)),
          ),
        );
    return id;
  }

  @override
  Future<void> renameConversation(String id, String title) {
    return _update(
      id,
      ConversationsCompanion(title: Value(title), updatedAt: Value(_now())),
    );
  }

  @override
  Future<void> updateConversationSettings(
    String id,
    ConversationSettings? settings,
  ) {
    return _update(
      id,
      ConversationsCompanion(
        settings: Value(_encodeSettings(settings)),
        updatedAt: Value(_now()),
      ),
    );
  }

  @override
  Future<void> updateLastPromptTokens(String id, int tokens) {
    return _update(id, ConversationsCompanion(lastPromptTokens: Value(tokens)));
  }

  @override
  Future<void> deleteConversation(String id) {
    // Attachments cascade from messages via FK; messages do not cascade
    // from conversations, so delete them explicitly in one transaction.
    return _db.transaction(() async {
      await (_db.delete(
        _db.messages,
      )..where((t) => t.conversationId.equals(id))).go();
      await (_db.delete(_db.conversations)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> _update(String id, ConversationsCompanion entry) async {
    await (_db.update(
      _db.conversations,
    )..where((t) => t.id.equals(id))).write(entry);
  }

  static String? _encodeSettings(ConversationSettings? settings) =>
      settings != null ? jsonEncode(settings.toJson()) : null;

  static model.Conversation _toModel(Conversation r) {
    ConversationSettings? settings;
    final raw = r.settings;
    if (raw != null) {
      try {
        settings = ConversationSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } on FormatException catch (e) {
        _log.warning('Corrupted settings JSON on ${r.id}, using defaults', e);
      } on TypeError catch (e) {
        _log.warning('Unexpected settings JSON on ${r.id}, using defaults', e);
      }
    }
    return model.Conversation(
      id: r.id,
      title: r.title,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
      systemPrompt: r.systemPrompt,
      settings: settings,
      lastPromptTokens: r.lastPromptTokens,
    );
  }
}
