/// Lifecycle state of a single [ChatSession].
///
/// The session manager owns one [ChatSession] per conversation and exposes
/// its state to the UI via a [ValueNotifier]. The UI never reads streaming
/// content from this state — partial assistant content is persisted in
/// Drift and watched through `conversationMessagesProvider`. This state
/// only carries the coarse lifecycle (idle / streaming / error) and the
/// token counters used by the context gauge.
sealed class ChatSessionState {
  const ChatSessionState();

  bool get isGenerating => this is SessionStreaming;
  int get promptTokens => 0;
  int get completionTokens => 0;
  int get totalTokens => promptTokens + completionTokens;
}

/// The session is not currently streaming. `promptTokens` may still be
/// non-zero — it reflects the last known prompt size for the conversation
/// so the context gauge does not reset between messages.
class SessionIdle extends ChatSessionState {
  @override
  final int promptTokens;
  @override
  final int completionTokens;

  const SessionIdle({
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}

/// A stream from the LLM is currently in flight. `streamingMessageId` is
/// the id of the placeholder row in the `messages` table that is being
/// written to incrementally.
class SessionStreaming extends ChatSessionState {
  final String streamingMessageId;
  @override
  final int promptTokens;
  @override
  final int completionTokens;

  const SessionStreaming({
    required this.streamingMessageId,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}

/// The last stream finished with an error. The error banner in the UI
/// reads `message`. Sending a new message transitions back to streaming.
class SessionError extends ChatSessionState {
  final String message;
  @override
  final int promptTokens;
  @override
  final int completionTokens;

  const SessionError({
    required this.message,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}
