import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_settings.dart';
import 'image_settings.dart';

part 'message_stats.freezed.dart';
part 'message_stats.g.dart';

/// How an assistant turn ended.
enum GenerationOutcome {
  /// The stream ended normally.
  completed,

  /// The user stopped it; what had arrived is kept.
  cancelled,

  /// The server or the connection failed mid-turn
  /// ([GenerationStats.error]).
  failed,

  /// Not over when the row was last written: still streaming, or the app
  /// quit or crashed before the stream ended.
  interrupted,
}

/// What was measured while a message was produced, and what it was
/// produced with.
///
/// Written with the message and never recomputed: the numbers of a turn
/// are history, whatever the settings say today. `null` on user messages
/// and on messages written before it existed.
@freezed
sealed class MessageStats with _$MessageStats {
  /// One assistant turn: a streamed `chat/completions` request.
  ///
  /// Times are milliseconds from [startedAt], when the request was sent,
  /// measured by the app (network included).
  const factory MessageStats.generation({
    /// The model the request named.
    required String model,

    /// Base URL of the server it went to.
    @Default('') String endpoint,

    /// Sampling parameters sent (text model), `null` for an image model.
    GenerationSettings? generation,

    /// Image options sent (image model), `null` for a text model.
    ImageSettings? image,

    /// What the request carried besides its messages — the system prompt
    /// as sent and the tool definitions — stored once per change in the
    /// conversation (`IConversationRepository.getRequestContexts`). `null`
    /// for an image model, which is sent neither.
    String? requestContextId,

    /// 0 for a turn the user asked for; n for the n-th automatic retry
    /// after a tool call the model wrote as text.
    @Default(0) int retry,
    required DateTime startedAt,

    /// Request sent → stream ended, whatever the [outcome].
    required int durationMs,

    /// Request sent → first output of any kind (reasoning, text, tool
    /// call, image). `null` when nothing came.
    int? firstTokenMs,

    /// Request sent → first output that is not reasoning. `null` when the
    /// turn only reasoned, or produced nothing.
    int? firstAnswerMs,

    /// Output fragments received (reasoning, text, tool-call pieces,
    /// images). About one per token on most servers: the only count left
    /// when the server reports no usage.
    @Default(0) int fragments,

    /// Token counts from the server's `usage`, `null` when it sent none.
    int? promptTokens,
    int? completionTokens,
    required GenerationOutcome outcome,
    String? error,

    /// What the context budget left out of this request: whole earlier
    /// exchanges, and images taken off the messages that stayed. Both `0`
    /// when the history went out as it was stored — which is the usual
    /// case, since trimming only starts once the window is nearly full.
    @Default(0) int droppedRuns,
    @Default(0) int droppedImages,

    /// Everything else the server said about the turn, verbatim: `usage`
    /// with its details, `finish_reason`, the model it actually ran,
    /// server-side `timings` (llama.cpp)… Later chunks overwrite earlier
    /// keys.
    @Default(<String, dynamic>{}) Map<String, dynamic> server,
  }) = GenerationStats;

  /// One tool call, run by the app on an MCP server.
  const factory MessageStats.toolCall({
    required DateTime startedAt,

    /// Call sent → result received (or failure).
    required int durationMs,

    /// The server that ran it; both `null` when no connected server
    /// provides the tool.
    String? serverId,
    String? serverName,
  }) = ToolCallStats;

  factory MessageStats.fromJson(Map<String, dynamic> json) =>
      _$MessageStatsFromJson(json);
}

/// What follows from the measures of a turn. Derived, never stored.
extension GenerationStatsX on GenerationStats {
  /// Generation proper: first output → end of the stream. What is left of
  /// [durationMs] once the prompt has been processed.
  int? get generationMs => switch (firstTokenMs) {
    null => null,
    final first => durationMs - first,
  };

  /// Reasoning: first output → first answer (or the end, for a turn that
  /// only reasoned). `null` when the turn did not start by reasoning.
  int? get reasoningMs {
    final first = firstTokenMs;
    if (first == null) return null;
    final answer = firstAnswerMs;
    if (answer == null) return durationMs - first;
    return answer > first ? answer - first : null;
  }

  /// Decoding speed: [completionTokens] over [generationMs], prompt
  /// processing left out. `null` without both.
  double? get outputTokensPerSecond {
    final tokens = completionTokens;
    final ms = generationMs;
    if (tokens == null || tokens <= 0 || ms == null || ms <= 0) return null;
    return tokens * 1000 / ms;
  }

  /// `finish_reason` as the server reported it (`stop`, `length`,
  /// `tool_calls`…).
  String? get finishReason => switch (server['finish_reason']) {
    final String reason => reason,
    _ => null,
  };
}
