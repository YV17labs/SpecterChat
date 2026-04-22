import '../models/conversation.dart';
import '../models/conversation_settings.dart';
import '../models/message.dart';

/// Contract for conversation and message persistence.
///
/// Decouples business logic from Drift/SQLite implementation,
/// enabling in-memory fakes for unit tests.
abstract interface class IConversationRepository {
  // --- Conversations ---
  Stream<List<Conversation>> watchAllConversations();
  Future<Conversation?> getConversation(String id);
  Future<String> createConversation({
    String? systemPrompt,
    ConversationSettings? settings,
  });
  Future<void> renameConversation(String id, String title);
  Future<void> updateConversationSettings(
      String id, ConversationSettings? settings);
  Future<void> updateLastPromptTokens(String id, int tokens);
  Future<void> deleteConversation(String id);

  // --- Messages ---

  /// Watch the most recent [limit] messages for a conversation, ordered
  /// chronologically. When [limit] is null, streams the full history —
  /// intended for tests or one-off administrative tools. UI callers
  /// should always pass a bounded [limit] so RAM stays proportional to
  /// what the user can actually see.
  Stream<List<Message>> watchMessages(String conversationId, {int? limit});

  /// Load the full message history. Used by the LLM pipeline to build
  /// API requests — the API needs the complete context, not a window.
  Future<List<Message>> getMessages(String conversationId);

  /// Stream the total count of persisted messages for the conversation,
  /// regardless of the UI window. Emits only on actual count changes so
  /// the UI can decide whether to show "load older messages" without
  /// firing a COUNT query on every streaming chunk.
  Stream<int> watchMessageCount(String conversationId);
  Future<void> saveMessage(Message message);
  Future<void> updateMessage(Message message);

  /// Upsert a message that is still being streamed. Called incrementally
  /// (~every 500ms) so the UI, which already watches the messages table,
  /// sees the response grow in real time and partial content survives
  /// conversation switches and app restarts.
  Future<void> upsertStreamingMessage(Message message);

  /// Mark a streaming message as complete. Flips `is_streaming` to false
  /// so the UI can stop showing the live-typing indicator.
  Future<void> finalizeStreamingMessage(String messageId);

  /// Delete a streaming placeholder that never received any content
  /// (e.g. stream cancelled before the first chunk).
  Future<void> deleteMessage(String messageId);

  /// Clear any `is_streaming` rows left behind by a previous app session
  /// that crashed mid-stream. Returns the number of rows reset.
  Future<int> clearOrphanStreamingFlags();
}
