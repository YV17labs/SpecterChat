import '../models/conversation.dart';
import '../models/message.dart';

/// Contract for conversation and message persistence.
///
/// Decouples business logic from Drift/SQLite implementation,
/// enabling in-memory fakes for unit tests.
abstract interface class IConversationRepository {
  // --- Conversations ---
  Stream<List<Conversation>> watchAllConversations();
  Future<String> createConversation({String? systemPrompt});
  Future<void> renameConversation(String id, String title);
  Future<void> deleteConversation(String id);

  // --- Messages ---
  Stream<List<Message>> watchMessages(String conversationId);
  Future<List<Message>> getMessages(String conversationId);
  Future<void> saveMessage(Message message);
  Future<void> updateMessage(Message message);
}
