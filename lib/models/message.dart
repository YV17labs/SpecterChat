
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
        final apiToolCalls = toolCalls.map((tc) {
          return {
            'id': tc.id,
            'type': 'function',
            'function': {
              'name': tc.name,
              'arguments':
                  tc.arguments.trim().isEmpty ? '{}' : tc.arguments,
            },
          };
        }).toList();

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
