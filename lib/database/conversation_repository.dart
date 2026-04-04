import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../models/conversation.dart' as model;
import '../models/message.dart' as model;
import '../utils/id_gen.dart';
import 'database.dart' as db;
import 'i_conversation_repository.dart';

/// Drift-backed implementation of [IConversationRepository].
class ConversationRepository implements IConversationRepository {
  final db.AppDatabase _database;

  ConversationRepository(this._database);

  @override
  Stream<List<model.Conversation>> watchAllConversations() {
    return _database.watchAllConversations().map((rows) => rows
        .map((r) => model.Conversation(
              id: r.id,
              title: r.title,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              systemPrompt: r.systemPrompt,
            ))
        .toList());
  }

  @override
  Future<String> createConversation({String? systemPrompt}) async {
    final id = generateId();
    final now = DateTime.now();
    await _database.insertConversation(db.ConversationsCompanion.insert(
      id: id,
      title: model.kDefaultConversationTitle,
      createdAt: now,
      updatedAt: now,
      systemPrompt: Value(systemPrompt),
    ));
    return id;
  }

  @override
  Future<void> renameConversation(String id, String title) async {
    await _database.updateConversation(db.ConversationsCompanion(
      id: Value(id),
      title: Value(title),
      updatedAt: Value(DateTime.now()),
    ));
  }

  @override
  Future<void> deleteConversation(String id) async {
    await _database.deleteConversationWithMessages(id);
  }

  @override
  Stream<List<model.Message>> watchMessages(String conversationId) {
    return _database
        .watchMessagesForConversation(conversationId)
        .map((rows) => rows.map(_dbMessageToModel).toList());
  }

  @override
  Future<List<model.Message>> getMessages(String conversationId) async {
    final rows =
        await _database.getMessagesForConversation(conversationId);
    return rows.map(_dbMessageToModel).toList();
  }

  @override
  Future<void> saveMessage(model.Message message) async {
    final contentJson =
        jsonEncode(message.content.map((c) => c.toJson()).toList());

    await _database.insertMessage(db.MessagesCompanion.insert(
      id: message.id,
      conversationId: message.conversationId,
      role: message.role.name,
      content: contentJson,
      completionTokens: Value(message.completionTokens),
      durationMs: Value(message.durationMs),
      createdAt: message.createdAt,
    ));

    await _database.updateConversation(db.ConversationsCompanion(
      id: Value(message.conversationId),
      updatedAt: Value(DateTime.now()),
    ));
  }

  @override
  Future<void> updateMessage(model.Message message) async {
    final contentJson =
        jsonEncode(message.content.map((c) => c.toJson()).toList());

    await _database.updateMessage(db.MessagesCompanion(
      id: Value(message.id),
      content: Value(contentJson),
    ));
  }

  static model.Message _dbMessageToModel(db.Message row) {
    final contentJson = jsonDecode(row.content) as List;
    final content = contentJson
        .map((c) =>
            model.ContentBlock.fromJson(c as Map<String, dynamic>))
        .toList();

    return model.Message(
      id: row.id,
      conversationId: row.conversationId,
      role: model.MessageRole.values.byName(row.role),
      content: content,
      createdAt: row.createdAt,
      completionTokens: row.completionTokens,
      durationMs: row.durationMs,
    );
  }
}
