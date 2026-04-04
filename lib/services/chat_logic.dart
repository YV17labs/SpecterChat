import '../models/message.dart';

/// Accumulates streamed tool call fragments into complete tool calls.
class ToolCallAccumulator {
  String? id;
  String? name;
  final StringBuffer argumentsBuffer = StringBuffer();

  bool get isValid => id != null && name != null;
}

/// Pure business logic for chat message building and API format conversion.
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
    for (final tc in toolCalls.values) {
      if (tc.isValid) {
        blocks.add(ContentBlock.toolCall(
          id: tc.id!,
          name: tc.name!,
          arguments: tc.argumentsBuffer.toString(),
        ));
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

  /// Build the API messages array from conversation history.
  List<Map<String, dynamic>> buildApiMessages({
    required List<Message> history,
    required String systemPrompt,
  }) {
    final messages = <Map<String, dynamic>>[];

    if (systemPrompt.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': systemPrompt,
      });
    }

    for (final msg in history) {
      messages.add(msg.toApiMessage());

      // Forward tool result images to the model as user messages
      // so vision-capable models can analyze them.
      if (msg.role == MessageRole.tool) {
        for (final block in msg.content) {
          if (block is ToolResultContentBlock &&
              block.imageBase64 != null) {
            messages.add({
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {
                    'url':
                        'data:${block.imageMimeType ?? "image/png"};base64,${block.imageBase64}',
                  },
                },
                {
                  'type': 'text',
                  'text':
                      'Here is the image result from tool "${block.toolName}".',
                },
              ],
            });
          }
        }
      }
    }

    return messages;
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
