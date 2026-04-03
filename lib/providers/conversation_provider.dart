import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart' as db;
import '../models/conversation.dart' as model;
import '../models/message.dart' as model;
import '../utils/id_gen.dart';
import 'database_provider.dart';

final conversationListProvider =
    StreamProvider<List<model.Conversation>>((ref) {
  final database = ref.watch(databaseProvider);
  return database.watchAllConversations().map((rows) => rows
      .map((r) => model.Conversation(
            id: r.id,
            title: r.title,
            createdAt: r.createdAt,
            updatedAt: r.updatedAt,
            systemPrompt: r.systemPrompt,
          ))
      .toList());
});

final selectedConversationIdProvider = StateProvider<String?>((ref) => null);

final selectedConversationProvider =
    Provider<model.Conversation?>((ref) {
  final id = ref.watch(selectedConversationIdProvider);
  if (id == null) return null;

  final listAsync = ref.watch(conversationListProvider);
  return listAsync.whenOrNull(
    data: (conversations) {
      try {
        return conversations.firstWhere((c) => c.id == id);
      } catch (_) {
        return null;
      }
    },
  );
});

final conversationMessagesProvider =
    StreamProvider.family<List<model.Message>, String>(
        (ref, conversationId) {
  final database = ref.watch(databaseProvider);
  return database.watchMessagesForConversation(conversationId).map(
      (rows) => rows.map((r) => _dbMessageToModel(r)).toList());
});

model.Message _dbMessageToModel(db.Message row) {
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
  );
}

class ConversationActions {
  final db.AppDatabase _database;

  ConversationActions(this._database);

  Future<String> createConversation({String? systemPrompt}) async {
    final id = generateId();
    final now = DateTime.now();
    await _database.insertConversation(db.ConversationsCompanion.insert(
      id: id,
      title: 'New Chat',
      createdAt: now,
      updatedAt: now,
      systemPrompt: Value(systemPrompt),
    ));
    return id;
  }

  Future<void> renameConversation(String id, String title) async {
    await _database.updateConversation(db.ConversationsCompanion(
      id: Value(id),
      title: Value(title),
      updatedAt: Value(DateTime.now()),
    ));
  }

  Future<void> deleteConversation(String id) async {
    await _database.deleteConversationWithMessages(id);
  }

  Future<void> saveMessage(model.Message message) async {
    final contentJson =
        jsonEncode(message.content.map((c) => c.toJson()).toList());

    await _database.insertMessage(db.MessagesCompanion.insert(
      id: message.id,
      conversationId: message.conversationId,
      role: message.role.name,
      content: contentJson,
      createdAt: message.createdAt,
    ));

    // Update conversation timestamp
    await _database.updateConversation(db.ConversationsCompanion(
      id: Value(message.conversationId),
      updatedAt: Value(DateTime.now()),
    ));
  }

  Future<void> updateMessage(model.Message message) async {
    final contentJson =
        jsonEncode(message.content.map((c) => c.toJson()).toList());

    await _database.updateMessage(db.MessagesCompanion(
      id: Value(message.id),
      content: Value(contentJson),
    ));
  }
}

final conversationActionsProvider = Provider<ConversationActions>((ref) {
  final database = ref.watch(databaseProvider);
  return ConversationActions(database);
});
