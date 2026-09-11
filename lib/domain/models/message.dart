import 'dart:convert';
import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'message.freezed.dart';
part 'message.g.dart';

/// Decoded bytes for an image attachment, keyed by attachment id when
/// passed around in bulk. The record shape keeps callers from having to
/// import any class just to hand bytes to the API serializer.
typedef ImageBytes = ({Uint8List bytes, String mimeType});

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
  const factory ContentBlock.image({
    required String attachmentId,
    required String mimeType,
    required int byteSize,
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
    @Default(0) int completionTokens,
    @Default(0) int durationMs,
  }) = _Message;

  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);
}

/// Read-only helpers over a message's content blocks.
extension MessageContentX on Message {
  /// All image attachment ids referenced anywhere in this message,
  /// including inside tool results.
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
