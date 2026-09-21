/// Progress of a long-running server-side step (image generation). The
/// service reports it as a `ProgressDelta`; the session keeps the latest
/// one on [SessionStreaming.progress] and drops it when the turn ends.
/// Fields are nullable because servers report whichever subset they know —
/// a stage name alone is valid.
class GenerationProgress {
  final String stage;
  final int? step;
  final int? total;
  final int? percent;
  final String? message;

  const GenerationProgress({
    required this.stage,
    this.step,
    this.total,
    this.percent,
    this.message,
  });

  /// 0..1 when the server gave enough to compute one, else `null`
  /// (the UI shows an indeterminate bar).
  double? get fraction {
    final p = percent;
    if (p != null) return (p.clamp(0, 100)) / 100;
    final s = step;
    final t = total;
    if (s != null && t != null && t > 0) return (s.clamp(0, t)) / t;
    return null;
  }

  /// Human label: the server's message when present, else "stage 12/40".
  String get label {
    final m = message;
    if (m != null && m.isNotEmpty) return m;
    final s = step;
    final t = total;
    if (s != null && t != null) return '$stage $s/$t';
    return stage;
  }
}

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

  // Transitions keep the token counters so the context gauge never resets
  // between turns.
  SessionIdle toIdle() => SessionIdle(
    promptTokens: promptTokens,
    completionTokens: completionTokens,
  );

  SessionStreaming toStreaming(String streamingMessageId) => SessionStreaming(
    streamingMessageId: streamingMessageId,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
  );

  /// Latest server-reported progress; only a streaming turn has one.
  GenerationProgress? get progress => null;

  /// Attach a progress report to the current streaming state. No-op (returns
  /// `this`) when not streaming — a late progress chunk after the turn has
  /// settled must not resurrect the streaming state.
  ChatSessionState withProgress(GenerationProgress? progress) => switch (this) {
    final SessionStreaming s => SessionStreaming(
      streamingMessageId: s.streamingMessageId,
      promptTokens: s.promptTokens,
      completionTokens: s.completionTokens,
      progress: progress,
    ),
    _ => this,
  };

  SessionError toError(String message) => SessionError(
    message: message,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
  );
}

/// The session is not currently streaming. `promptTokens` may still be
/// non-zero — it reflects the last known prompt size for the conversation
/// so the context gauge does not reset between messages.
class SessionIdle extends ChatSessionState {
  @override
  final int promptTokens;
  @override
  final int completionTokens;

  const SessionIdle({this.promptTokens = 0, this.completionTokens = 0});
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

  @override
  final GenerationProgress? progress;

  const SessionStreaming({
    required this.streamingMessageId,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.progress,
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
