import '../models/message.dart';

/// Persistence contract for messages, including the incremental writes the
/// streaming pipeline relies on.
abstract interface class IMessageRepository {
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

  /// Insert a finished message and bump the conversation's `updatedAt`.
  Future<void> saveMessage(Message message);

  /// Upsert a message that is still being streamed. Called incrementally
  /// so the UI, which already watches the messages table, sees the
  /// response grow in real time and partial content survives conversation
  /// switches and app restarts.
  Future<void> upsertStreamingMessage(Message message);

  /// Mark a streaming message as complete. Flips `is_streaming` to false
  /// so the UI can stop showing the live-typing indicator.
  Future<void> finalizeStreamingMessage(String messageId);

  /// Delete a message by id — used to drop a streaming placeholder that
  /// never received any content.
  Future<void> deleteMessage(String messageId);

  /// Run [action] inside a database transaction. Reactive streams only
  /// emit on the committed snapshot, so callers that touch multiple
  /// tables (e.g. a tool message and its attachment blobs) can make the
  /// writes appear atomically to UI watchers.
  Future<T> runInTransaction<T>(Future<T> Function() action);
}
