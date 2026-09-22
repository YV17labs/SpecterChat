import '../models/conversation.dart';
import '../models/conversation_settings.dart';
import '../models/request_context.dart';

/// Persistence contract for conversations (the rows, not their messages —
/// see `IMessageRepository`). Decouples business logic from Drift/SQLite so
/// unit tests can use in-memory fakes.
abstract interface class IConversationRepository {
  Stream<List<Conversation>> watchAllConversations();

  /// `null` when no conversation has that id.
  Future<Conversation?> getConversation(String id);

  /// Creates a conversation with the default title and returns its id.
  Future<String> createConversation({
    String? systemPrompt,
    ConversationSettings? settings,
  });

  Future<void> renameConversation(String id, String title);

  Future<void> updateConversationSettings(
    String id,
    ConversationSettings? settings,
  );

  Future<void> updateLastPromptTokens(String id, int tokens);

  /// Removes the conversation, its messages and their attachments.
  Future<void> deleteConversation(String id);

  /// Store what [conversationId]'s requests carry besides their messages,
  /// and return the id to record with the turns that carried it. Contexts
  /// are identified by their content: storing the same one twice stores it
  /// once and returns the same id.
  Future<String> saveRequestContext(
    String conversationId,
    RequestContext context,
  );

  /// Every request context stored for [conversationId], by id.
  Future<Map<String, RequestContext>> getRequestContexts(String conversationId);
}
