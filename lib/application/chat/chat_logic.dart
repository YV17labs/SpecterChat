import '../../core/id_gen.dart';
import '../../domain/models/message.dart';
import '../../domain/models/message_stats.dart';
import '../../domain/models/photo_metadata.dart';
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

  /// Build an assistant [Message] from accumulated stream buffers, with
  /// what was measured of the turn so far ([stats]), whose token count and
  /// duration also fill the message's own columns.
  Message buildAssistantMessage({
    required String id,
    required String conversationId,
    required String content,
    required String thinking,
    required List<ToolCallAccumulator> toolCalls,
    required bool isStreaming,
    List<ImageContentBlock> images = const [],
    GenerationStats? stats,
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
    for (final tc in toolCalls) {
      if (tc.isValid) {
        blocks.add(
          ContentBlock.toolCall(
            id: tc.callId,
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
      completionTokens: stats?.completionTokens ?? 0,
      durationMs: stats?.durationMs ?? 0,
      stats: stats,
    );
  }

  /// A user turn and the blobs to store with it, in the same transaction
  /// (`saveMessagesWithAttachments`): the text block (when there is text),
  /// then one image block per entry of [images], backed by an attachment
  /// of its bytes. An image's photo metadata is split: what is shown stays
  /// on its block, the verbatim blocks go to an attachment of their own —
  /// one for the images that share them (an annotated copy and its
  /// original). [newId] mints the attachment ids.
  MessageWrite buildUserMessage({
    required String id,
    required String conversationId,
    required String text,
    List<DescribedImage> images = const [],
    String Function() newId = generateId,
  }) {
    final attachments = <PendingAttachment>[];
    final blocksIds = <PhotoMetadataBlocks, String>{};
    String storeBlocks(PhotoMetadataBlocks blocks) {
      final blocksId = newId();
      attachments.add(
        PendingAttachment.photoMetadata(attachmentId: blocksId, blocks: blocks),
      );
      return blocksId;
    }

    final content = <ContentBlock>[
      if (text.isNotEmpty) ContentBlock.text(text: text),
    ];
    for (final image in images) {
      final attachmentId = newId();
      attachments.add(
        PendingAttachment(
          attachmentId: attachmentId,
          bytes: image.bytes,
          mimeType: image.mimeType,
        ),
      );
      final metadata = switch (image.metadata) {
        null => null,
        PhotoMetadata(:final summary, :final blocks) => PhotoMetadataRef(
          summary: summary,
          blocksId: blocks.isEmpty
              ? null
              : blocksIds.putIfAbsent(blocks, () => storeBlocks(blocks)),
        ),
      };
      content.add(
        ContentBlock.image(
          attachmentId: attachmentId,
          mimeType: image.mimeType,
          byteSize: image.bytes.length,
          photoMetadata: metadata,
          aiOrigin: image.aiOrigin,
        ),
      );
    }
    return MessageWrite(
      Message(
        id: id,
        conversationId: conversationId,
        role: MessageRole.user,
        content: content,
        createdAt: DateTime.now(),
      ),
      attachments: attachments,
    );
  }

  /// Where an image the model is producing comes from: how it was made,
  /// and the photo metadata it inherits — that of its reference, whose
  /// blocks the caller copies for it. Decided once, when its block is
  /// written.
  ///
  /// [textToImage] is what the server says it did. Drawn from the prompt
  /// alone, the image is [AiOrigin.generated] and inherits nothing.
  /// Otherwise it starts from a reference — assumed whenever there is one
  /// when the server does not say — and is an [AiOrigin.editedPhoto] even
  /// when nothing is known about that reference (a screenshot).
  ///
  /// The references are the images of the last user turn; when that turn
  /// has none the server reuses the latest image of the conversation ("now
  /// make it blue"), which may itself have inherited from an earlier photo
  /// — so the metadata follows a chain of edits. Among several references
  /// the first one carrying metadata wins.
  ({AiOrigin origin, PhotoMetadataRef? metadata}) generatedImageOrigin(
    List<Message> history, {
    bool? textToImage,
  }) {
    const fromPrompt = (origin: AiOrigin.generated, metadata: null);
    if (textToImage ?? false) return fromPrompt;
    final references = _referenceImages(history);
    if (references.isEmpty && textToImage == null) return fromPrompt;
    return (
      origin: AiOrigin.editedPhoto,
      metadata: references.map((b) => b.photoMetadata).nonNulls.firstOrNull,
    );
  }

  /// The images an image model works from (see [generatedImageOrigin]).
  List<ImageContentBlock> _referenceImages(List<Message> history) {
    final lastUser = history.lastIndexWhere((m) => m.role == MessageRole.user);
    if (lastUser < 0) return const [];
    final attached = history[lastUser].content
        .whereType<ImageContentBlock>()
        .toList();
    if (attached.isNotEmpty) return attached;
    for (final message in history.take(lastUser).toList().reversed) {
      final images = message.content.whereType<ImageContentBlock>();
      if (images.isNotEmpty) return [images.last];
    }
    return const [];
  }

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
