import '../../domain/models/message.dart';
import '../../domain/services/llm_hook.dart';
import 'message_writes.dart';
import 'stream_accumulator.dart';

/// What to do with a finished assistant turn.
///
/// Derived once from the accumulated buffers by [ChatLogic.analyzeCompletion]
/// so the session's control flow reads as a handful of booleans instead of
/// re-deriving the same conditions in three places.
class CompletionAnalysis {
  /// The model produced a tool call as text/XML instead of a native call.
  final bool hallucinated;

  /// The server stripped a malformed tool call before it reached us: the
  /// turn is empty apart from thinking. Treated like a hallucination.
  final bool suppressed;
  final bool _hasValidToolCalls;
  final bool _isSendable;

  const CompletionAnalysis._({
    required this.hallucinated,
    required this.suppressed,
    required bool hasValidToolCalls,
    required bool isSendable,
  }) : _hasValidToolCalls = hasValidToolCalls,
       _isSendable = isSendable;

  bool get keepMessage => _isSendable && !hallucinated;
  bool get shouldRunTools => _hasValidToolCalls && !hallucinated;
  bool get shouldRetry => hallucinated || suppressed;
}

/// Pure business logic for chat message building.
///
/// Stateless and side-effect-free — every method is independently testable
/// without mocking any external dependency.
class ChatLogic {
  const ChatLogic();

  /// Build an assistant [Message] from accumulated stream buffers.
  Message buildAssistantMessage({
    required String id,
    required String conversationId,
    required String content,
    required String thinking,
    required Map<int, ToolCallAccumulator> toolCalls,
    required bool isStreaming,
    List<ImageContentBlock> images = const [],
    int completionTokens = 0,
    int durationMs = 0,
  }) {
    final blocks = <ContentBlock>[];

    if (thinking.isNotEmpty) {
      blocks.add(ContentBlock.thinking(text: thinking));
    }
    if (content.isNotEmpty) {
      blocks.add(ContentBlock.text(text: content));
    }
    // Images follow the text: the text buffer is a single block, so a
    // caption streamed after the image still reads above it.
    blocks.addAll(images);
    for (final tc in toolCalls.values) {
      if (tc.isValid) {
        blocks.add(
          ContentBlock.toolCall(
            id: tc.id!,
            name: tc.name!,
            arguments: tc.arguments,
          ),
        );
      }
    }

    if (blocks.isEmpty) {
      blocks.add(const ContentBlock.text(text: ''));
    }

    return Message(
      id: id,
      conversationId: conversationId,
      role: MessageRole.assistant,
      content: blocks,
      createdAt: DateTime.now(),
      isStreaming: isStreaming,
      completionTokens: completionTokens,
      durationMs: durationMs,
    );
  }

  /// A user turn: the text block (when there is text) followed by one
  /// image block per entry of [images]. The caller stores the blobs under
  /// those ids in the same transaction as the row
  /// (`saveMessagesWithAttachments`).
  Message buildUserMessage({
    required String id,
    required String conversationId,
    required String text,
    List<PendingAttachment> images = const [],
  }) => Message(
    id: id,
    conversationId: conversationId,
    role: MessageRole.user,
    content: [
      if (text.isNotEmpty) ContentBlock.text(text: text),
      for (final a in images)
        ContentBlock.image(
          attachmentId: a.attachmentId,
          mimeType: a.mimeType,
          byteSize: a.bytes.length,
        ),
    ],
    createdAt: DateTime.now(),
  );

  /// Classify a finished turn from its buffers. [hook] is the model-specific
  /// hook, or `null` when the selected model has no known quirks.
  CompletionAnalysis analyzeCompletion(
    StreamAccumulator turn, {
    LlmHook? hook,
  }) {
    final content = turn.content.toString();
    final thinking = turn.thinking.toString();
    final hallucinated =
        hook != null &&
        (hook.detectHallucination(content) ||
            hook.detectHallucination(thinking));
    // Symptom-based fallback: the server may strip a malformed tool-call
    // wrapper before any of it reaches us (mlx_vlm does this when Qwen3
    // emits XML-style arguments inside <tool_call>…</tool_call>). The
    // visible result is an otherwise-empty turn where the model clearly
    // thought but produced nothing usable.
    final suppressed =
        hook != null &&
        !hallucinated &&
        !turn.isSendable &&
        thinking.isNotEmpty;
    return CompletionAnalysis._(
      hallucinated: hallucinated,
      suppressed: suppressed,
      hasValidToolCalls: turn.hasValidToolCalls,
      isSendable: turn.isSendable,
    );
  }

  /// Every image attachment id referenced by [history], de-duplicated.
  /// Used by the chat pipeline to batch-load bytes from the attachment
  /// repository before calling the LLM service.
  Set<String> collectImageAttachmentIds(List<Message> history) {
    final ids = <String>{};
    for (final msg in history) {
      ids.addAll(msg.imageAttachmentIds());
    }
    return ids;
  }

  /// Generate an auto-title from the first assistant response.
  ///
  /// Returns `null` if no suitable title can be derived.
  String? generateAutoTitle(String assistantResponse) {
    final firstLine = assistantResponse.split('\n').first.trim();
    if (firstLine.isEmpty) return null;

    return firstLine.length > 50
        ? '${firstLine.substring(0, 47)}...'
        : firstLine;
  }
}
