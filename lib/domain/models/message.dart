import 'dart:convert';
import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

import 'message_stats.dart';
import 'photo_metadata.dart';

part 'message.freezed.dart';
part 'message.g.dart';

/// Decoded bytes for an image attachment, keyed by attachment id when
/// passed around in bulk. The record shape keeps callers from having to
/// import any class just to hand bytes to the API serializer.
typedef ImageBytes = ({Uint8List bytes, String mimeType});

/// An image and what is known about it: [metadata], what the photo it
/// comes from said about itself, and [aiOrigin], how a model made it.
///
/// What the composer holds and sends — the two are then kept on the image
/// block for "Save as…", they are not part of the request — and what an
/// image of the conversation comes back as for "Annotate & reuse".
class DescribedImage {
  final Uint8List bytes;
  final String mimeType;
  final PhotoMetadata? metadata;
  final AiOrigin? aiOrigin;

  const DescribedImage({
    required this.bytes,
    required this.mimeType,
    this.metadata,
    this.aiOrigin,
  });

  /// The same picture as other [bytes] (an annotated copy): still the same
  /// photo, made the same way.
  DescribedImage withBytes(Uint8List bytes, String mimeType) => DescribedImage(
    bytes: bytes,
    mimeType: mimeType,
    metadata: metadata,
    aiOrigin: aiOrigin,
  );
}

/// Map of attachment id → decoded bytes, preloaded by the chat pipeline
/// before building an API request. The empty map is a valid input —
/// images with unresolved ids are silently dropped from the payload.
typedef ImageBytesMap = Map<String, ImageBytes>;

enum MessageRole { system, user, assistant, tool }

/// Represents a content block within a message (text, image, tool call, etc.)
@freezed
sealed class ContentBlock with _$ContentBlock {
  const factory ContentBlock.text({required String text}) = TextContentBlock;

  /// Image stored as a blob attachment. The content block holds only the
  /// attachment id + metadata — actual bytes are loaded on demand via
  /// `IAttachmentRepository`. This keeps `List<Message>` small in RAM.
  ///
  /// [photoMetadata] is what the photo behind this image said about itself:
  /// read from the file the user attached, or inherited by an image the
  /// model made from it. Kept here — what is shown of it, the rest in an
  /// attachment of its own — not in the bytes, and written into the file
  /// only when the user saves it.
  ///
  /// [aiOrigin] says how a model made the image, `null` when none did (a
  /// photo, a screenshot, a tool result). Set once, when the block is
  /// written: by the chat session for a streamed image, carried along when
  /// the user sends a result again. Blocks written before it existed get it
  /// from their message's role when read (`MessageRepository`).
  const factory ContentBlock.image({
    required String attachmentId,
    required String mimeType,
    required int byteSize,
    PhotoMetadataRef? photoMetadata,
    AiOrigin? aiOrigin,
  }) = ImageContentBlock;

  const factory ContentBlock.toolCall({
    required String id,
    required String name,
    required String arguments,
  }) = ToolCallContentBlock;

  const factory ContentBlock.toolResult({
    required String toolCallId,
    required String toolName,
    @Default(<ContentBlock>[]) List<ContentBlock> resultContent,
    @Default('') String rawResponse,
  }) = ToolResultContentBlock;

  const factory ContentBlock.thinking({required String text}) =
      ThinkingContentBlock;

  factory ContentBlock.fromJson(Map<String, dynamic> json) =>
      _$ContentBlockFromJson(json);
}

/// A single message in a conversation.
@freezed
abstract class Message with _$Message {
  const factory Message({
    required String id,
    required String conversationId,
    required MessageRole role,
    required List<ContentBlock> content,
    required DateTime createdAt,
    @Default(false) bool isStreaming,

    /// Output tokens the server reported for an assistant turn.
    @Default(0) int completionTokens,

    /// Time it took to produce: the generation of an assistant turn, the
    /// call of a tool result.
    @Default(0) int durationMs,

    /// Everything measured while it was produced, with what it was
    /// produced with (model, settings, server report).
    MessageStats? stats,
  }) = _Message;

  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);
}

/// Read-only helpers over a message's content blocks.
extension MessageContentX on Message {
  /// All image attachment ids referenced anywhere in this message,
  /// including inside tool results. The attachments holding photo metadata
  /// (`PhotoMetadataRef.blocksId`) are not images: they are left out, so
  /// they are never loaded with the pictures nor sent to the model.
  List<String> imageAttachmentIds() {
    final ids = <String>[];
    for (final block in content) {
      if (block is ImageContentBlock) {
        ids.add(block.attachmentId);
      } else if (block is ToolResultContentBlock) {
        for (final inner in block.resultContent) {
          if (inner is ImageContentBlock) ids.add(inner.attachmentId);
        }
      }
    }
    return ids;
  }

  /// Concatenated text blocks, or the empty string.
  String get plainText =>
      content.whereType<TextContentBlock>().map((b) => b.text).join();

  /// Whether a picture is shown anywhere in this message, a tool result's
  /// own content included.
  bool get hasImages => content.any(
    (block) => switch (block) {
      ImageContentBlock() => true,
      ToolResultContentBlock(:final resultContent) => resultContent.any(
        (inner) => inner is ImageContentBlock,
      ),
      _ => false,
    },
  );

  /// What this message weighs: its images as they are stored plus its
  /// text as UTF-8. The token counts say nothing about the size of a
  /// picture, and a picture is most of what a message weighs.
  int get contentBytes => contentBytesOf(content);
}

/// What [blocks] weigh, the content of a tool result included.
int contentBytesOf(Iterable<ContentBlock> blocks) {
  var bytes = 0;
  for (final block in blocks) {
    bytes += switch (block) {
      TextContentBlock(:final text) => utf8Length(text),
      ThinkingContentBlock(:final text) => utf8Length(text),
      ToolCallContentBlock(:final name, :final arguments) =>
        utf8Length(name) + utf8Length(arguments),
      ImageContentBlock(:final byteSize) => byteSize,
      // The raw response is the same content again, in the server's own
      // shape, and its images are references — counting it would count
      // them twice.
      ToolResultContentBlock(:final resultContent) => contentBytesOf(
        resultContent,
      ),
    };
  }
  return bytes;
}

/// The bytes [text] takes as UTF-8, counted rather than encoded: this runs
/// while a reply streams, and again over every message of a history the
/// context budget has to weigh.
///
/// Walked as UTF-16 code units rather than runes, which decode surrogate
/// pairs to count them: a pair is four UTF-8 bytes, so two for each half
/// gives the same answer without putting it back together.
int utf8Length(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    bytes += unit < 0x80
        ? 1
        : unit < 0x800
        ? 2
        : (unit & 0xF800) == 0xD800
        ? 2
        : 3;
  }
  return bytes;
}

/// Everything that follows from a message's [Message.stats] — what it
/// weighed, how fast it came, when it was produced — the same wherever it
/// is shown or exported.
extension MessageMeasuresX on Message {
  /// What was measured of this assistant turn, `null` for other messages
  /// and replies written before stats existed.
  GenerationStats? get generationStats => switch (stats) {
    final GenerationStats g => g,
    _ => null,
  };

  /// When the turn ran: the moment its request was sent, else the row's
  /// own time for a message written before stats existed.
  DateTime get generatedAt => generationStats?.startedAt ?? createdAt;

  /// Input tokens the server counted for this turn — the whole context it
  /// was sent. `null` when the server reported no `usage`, for an image
  /// turn and for replies written before stats existed;
  /// [Message.completionTokens] is the output side of it.
  int? get promptTokens => generationStats?.promptTokens;

  /// Output tokens over the whole [Message.durationMs], prompt processing
  /// included — the only speed a reply without stats has.
  double? get overallTokensPerSecond => completionTokens > 0 && durationMs > 0
      ? completionTokens * 1000 / durationMs
      : null;

  /// The decoding speed when it was measured, else [overallTokensPerSecond].
  double? get tokensPerSecond =>
      generationStats?.outputTokensPerSecond ?? overallTokensPerSecond;
}

/// A streamed `tool_call.function.arguments` string is truncated if the
/// stream breaks mid-call; replaying such a message poisons the whole
/// conversation because the server rejects the malformed JSON on every
/// subsequent turn. An empty string is valid (`{}` is implied).
bool hasParseableToolCallArgs(String args) {
  final trimmed = args.trim();
  if (trimmed.isEmpty) return true;
  try {
    jsonDecode(trimmed);
    return true;
  } on FormatException {
    return false;
  }
}
