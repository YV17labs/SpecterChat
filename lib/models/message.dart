
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

enum MessageRole {
  system,
  user,
  assistant,
  tool,
}

/// Represents a content block within a message (text, image, tool call, etc.)
@freezed
sealed class ContentBlock with _$ContentBlock {
  const factory ContentBlock.text({
    required String text,
  }) = TextContentBlock;

  /// Image stored as a blob attachment. The content block holds only the
  /// attachment id + metadata — actual bytes are loaded on demand via
  /// [IAttachmentRepository]. This keeps `List<Message>` small in RAM.
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

  const factory ContentBlock.thinking({
    required String text,
  }) = ThinkingContentBlock;

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

/// Convert a [Message] to the wire format expected by OpenAI-compatible
/// chat/completions endpoints.
///
/// Image bytes are never stored on [Message] itself — the pipeline preloads
/// them into [imageBytes] so the model layer stays a pure data container.
/// Unresolved attachment ids (deleted, corrupted, not-yet-loaded) are
/// silently dropped; the surrounding text/tool structure is preserved.
extension MessageToApi on Message {
  List<Map<String, dynamic>> toApiContent(ImageBytesMap imageBytes) {
    final parts = <Map<String, dynamic>>[];
    for (final block in content) {
      switch (block) {
        case TextContentBlock(:final text):
          parts.add({'type': 'text', 'text': text});
        case ImageContentBlock(:final attachmentId):
          final loaded = imageBytes[attachmentId];
          if (loaded == null) break;
          parts.add({
            'type': 'image_url',
            'image_url': {
              'url':
                  'data:${loaded.mimeType};base64,${base64Encode(loaded.bytes)}',
            },
          });
        case ThinkingContentBlock():
        case ToolCallContentBlock():
        case ToolResultContentBlock():
          break;
      }
    }
    return parts;
  }

  Map<String, dynamic> toApiMessage(ImageBytesMap imageBytes) {
    if (role == MessageRole.assistant) {
      final toolCalls = content.whereType<ToolCallContentBlock>().toList();
      if (toolCalls.isNotEmpty) {
        final apiToolCalls = toolCalls
            .map((tc) => {
                  'id': tc.id,
                  'type': 'function',
                  'function': {
                    'name': tc.name,
                    'arguments':
                        tc.arguments.trim().isEmpty ? '{}' : tc.arguments,
                  },
                })
            .toList();
        final textParts = content.whereType<TextContentBlock>().toList();
        return {
          'role': 'assistant',
          'content': textParts.isNotEmpty ? textParts.first.text : null,
          'tool_calls': apiToolCalls,
        };
      }
    }

    if (role == MessageRole.tool) {
      final result = content.whereType<ToolResultContentBlock>().firstOrNull;
      if (result != null) {
        final texts = result.resultContent
            .whereType<TextContentBlock>()
            .map((t) => t.text)
            .join('\n');
        return {
          'role': 'tool',
          'tool_call_id': result.toolCallId,
          'content': texts,
        };
      }
    }

    final apiContent = toApiContent(imageBytes);
    if (apiContent.length == 1 && apiContent.first['type'] == 'text') {
      return {
        'role': role.name,
        'content': apiContent.first['text'] as String,
      };
    }
    return {
      'role': role.name,
      'content': apiContent,
    };
  }

  /// All image attachment ids referenced anywhere in this message.
  Iterable<String> imageAttachmentIds() sync* {
    for (final block in content) {
      if (block is ImageContentBlock) {
        yield block.attachmentId;
      } else if (block is ToolResultContentBlock) {
        for (final inner in block.resultContent) {
          if (inner is ImageContentBlock) yield inner.attachmentId;
        }
      }
    }
  }
}
