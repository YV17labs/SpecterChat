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

    // Pending image content parts collected from consecutive tool results.
    // Flushed as a single user message once the tool-result run ends,
    // so we never break the required tool-message sequence (OpenAI spec
    // mandates all tool results appear consecutively after the assistant
    // tool_calls message).
    var pendingImageParts = <Map<String, dynamic>>[];

    for (var i = 0; i < history.length; i++) {
      final msg = history[i];
      messages.add(msg.toApiMessage());

      // Collect images from tool results — the spec only allows text in
      // tool-role content, so images must go in a separate user message.
      if (msg.role == MessageRole.tool) {
        for (final block in msg.content) {
          if (block is ToolResultContentBlock) {
            for (final inner in block.resultContent) {
              if (inner is ImageContentBlock) {
                pendingImageParts.add({
                  'type': 'image_url',
                  'image_url': {
                    'url':
                        'data:${inner.mimeType};base64,${inner.base64Data}',
                  },
                });
                pendingImageParts.add({
                  'type': 'text',
                  'text':
                      'Image result from tool "${block.toolName}".',
                });
              }
            }
          }
        }
      }

      // Flush pending images when the consecutive tool-result run ends
      // (next message is not a tool, or we reached the end of history).
      if (pendingImageParts.isNotEmpty) {
        final nextIsNotTool = i + 1 >= history.length ||
            history[i + 1].role != MessageRole.tool;
        if (nextIsNotTool) {
          messages.add({
            'role': 'user',
            'content': pendingImageParts,
          });
          pendingImageParts = <Map<String, dynamic>>[];
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
