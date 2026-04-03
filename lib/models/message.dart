import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'message.freezed.dart';
part 'message.g.dart';

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

  const factory ContentBlock.image({
    required String base64Data,
    required String mimeType,
  }) = ImageContentBlock;

  const factory ContentBlock.toolCall({
    required String id,
    required String name,
    required String arguments,
  }) = ToolCallContentBlock;

  const factory ContentBlock.toolResult({
    required String toolCallId,
    required String toolName,
    required String content,
    String? imageBase64,
    String? imageMimeType,
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
  }) = _Message;

  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);
}

/// Extension to convert messages to OpenAI API format.
extension MessageToApi on Message {
  List<Map<String, dynamic>> toApiContent() {
    final List<Map<String, dynamic>> parts = [];

    for (final block in content) {
      switch (block) {
        case TextContentBlock(:final text):
          parts.add({'type': 'text', 'text': text});
        case ImageContentBlock(:final base64Data, :final mimeType):
          parts.add({
            'type': 'image_url',
            'image_url': {
              'url': 'data:$mimeType;base64,$base64Data',
            },
          });
        case ThinkingContentBlock():
          // Thinking blocks are not sent to the API
          break;
        case ToolCallContentBlock():
          // Handled separately
          break;
        case ToolResultContentBlock():
          // Handled separately
          break;
      }
    }

    return parts;
  }

  /// Convert to the format expected by OpenAI-compatible APIs.
  Map<String, dynamic> toApiMessage() {
    if (role == MessageRole.assistant) {
      // Check for tool calls
      final toolCalls = content.whereType<ToolCallContentBlock>().toList();
      if (toolCalls.isNotEmpty) {
        final apiToolCalls = toolCalls
            .map((tc) => {
                  return {
                    'id': tc.id,
                    'type': 'function',
                    'function': {
                      'name': tc.name,
                      'arguments': tc.arguments,
                    },
                  };
                })
            .toList();

        final textParts = content.whereType<TextContentBlock>().toList();
        return {
          'role': 'assistant',
          if (textParts.isNotEmpty) 'content': textParts.first.text,
          'tool_calls': apiToolCalls,
        };
      }
    }

    if (role == MessageRole.tool) {
      final result = content.whereType<ToolResultContentBlock>().first;
      return {
        'role': 'tool',
        'tool_call_id': result.toolCallId,
        'content': result.content,
      };
    }

    final apiContent = toApiContent();
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
}
