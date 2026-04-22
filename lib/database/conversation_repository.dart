import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../models/conversation.dart' as model;
import '../models/conversation_settings.dart';
import '../models/message.dart' as model;
import '../utils/id_gen.dart';
import 'database.dart' as db;
import 'i_conversation_repository.dart';

/// Drift-backed implementation of [IConversationRepository].
String? _encodeSettings(ConversationSettings? settings) =>
    settings != null ? jsonEncode(settings.toJson()) : null;

class ConversationRepository implements IConversationRepository {
  final db.AppDatabase _database;

  ConversationRepository(this._database);

  @override
  Stream<List<model.Conversation>> watchAllConversations() {
    return _database.watchAllConversations().map((rows) => rows
        .map(_dbConversationToModel)
        .toList());
  }

  @override
  Future<model.Conversation?> getConversation(String id) async {
    try {
      final row = await _database.getConversation(id);
      return _dbConversationToModel(row);
    } catch (_) {
      return null;
    }
  }

  static model.Conversation _dbConversationToModel(db.Conversation r) {
    ConversationSettings? settings;
    if (r.settings != null) {
      try {
        settings = ConversationSettings.fromJson(
            jsonDecode(r.settings!) as Map<String, dynamic>);
      } catch (_) {
        // Corrupted JSON — ignore, use defaults.
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

  @override
  Future<String> createConversation({
    String? systemPrompt,
    ConversationSettings? settings,
  }) async {
    final id = generateId();
    final now = DateTime.now();
    await _database.insertConversation(db.ConversationsCompanion.insert(
      id: id,
      title: model.kDefaultConversationTitle,
      createdAt: now,
      updatedAt: now,
      systemPrompt: Value(systemPrompt),
      settings: Value(
          _encodeSettings(settings)),
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
  Future<void> updateConversationSettings(
      String id, ConversationSettings? settings) async {
    await _database.updateConversation(db.ConversationsCompanion(
      id: Value(id),
      settings: Value(
          _encodeSettings(settings)),
      updatedAt: Value(DateTime.now()),
    ));
  }

  @override
  Future<void> updateLastPromptTokens(String id, int tokens) async {
    await _database.updateConversation(db.ConversationsCompanion(
      id: Value(id),
      lastPromptTokens: Value(tokens),
    ));
  }

  @override
  Future<void> deleteConversation(String id) async {
    await _database.deleteConversationWithMessages(id);
  }

  @override
  Stream<List<model.Message>> watchMessages(
    String conversationId, {
    int? limit,
  }) {
    return _database
        .watchRecentMessagesForConversation(
          conversationId,
          limit: limit ?? 0,
        )
        .map((rows) => rows.map(_dbMessageToModel).toList());
  }

  @override
  Future<List<model.Message>> getMessages(String conversationId) async {
    final rows =
        await _database.getMessagesForConversation(conversationId);
    return rows.map(_dbMessageToModel).toList();
  }

  @override
  Stream<int> watchMessageCount(String conversationId) {
    return _database.watchMessageCountForConversation(conversationId);
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
      isStreaming: Value(message.isStreaming),
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
      isStreaming: Value(message.isStreaming),
      updatedAt: Value(DateTime.now()),
    ));
  }

  @override
  Future<void> upsertStreamingMessage(model.Message message) async {
    final contentJson =
        jsonEncode(message.content.map((c) => c.toJson()).toList());

    await _database.upsertMessage(db.MessagesCompanion.insert(
      id: message.id,
      conversationId: message.conversationId,
      role: message.role.name,
      content: contentJson,
      completionTokens: Value(message.completionTokens),
      durationMs: Value(message.durationMs),
      createdAt: message.createdAt,
      isStreaming: const Value(true),
      updatedAt: Value(DateTime.now()),
    ));
  }

  @override
  Future<void> finalizeStreamingMessage(String messageId) async {
    await _database.markMessageFinalized(messageId);
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    await _database.deleteMessage(messageId);
  }

  @override
  Future<int> clearOrphanStreamingFlags() {
    return _database.clearOrphanStreamingFlags();
  }

  static model.Message _dbMessageToModel(db.Message row) {
    final contentJson = jsonDecode(row.content) as List;
    final content = contentJson.map((c) {
      final map = c as Map<String, dynamic>;
      // Migrate old ToolResultContentBlock format (content/imageBase64 fields)
      // to the new resultContent list.
      if (map['runtimeType'] == 'toolResult' &&
          !map.containsKey('resultContent')) {
        final migrated = <Map<String, dynamic>>[];
        final oldContent = map['content'] as String?;
        if (oldContent != null && oldContent.isNotEmpty) {
          migrated.add({'runtimeType': 'text', 'text': oldContent});
        }
        final oldImage = map['imageBase64'] as String?;
        if (oldImage != null) {
          migrated.add({
            'runtimeType': 'image',
            'base64Data': oldImage,
            'mimeType': map['imageMimeType'] ?? 'image/png',
          });
        }
        map['resultContent'] = migrated;
        map.remove('content');
        map.remove('imageBase64');
        map.remove('imageMimeType');
      }
      return model.ContentBlock.fromJson(map);
    }).toList();

    return model.Message(
      id: row.id,
      conversationId: row.conversationId,
      role: model.MessageRole.values.byName(row.role),
      content: content,
      createdAt: row.createdAt,
      completionTokens: row.completionTokens,
      durationMs: row.durationMs,
      isStreaming: row.isStreaming,
    );
  }
}
