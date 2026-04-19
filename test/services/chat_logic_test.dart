import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/models/message.dart';
import 'package:specterchat/services/chat_logic.dart';

void main() {
  const logic = ChatLogic();

  group('ChatLogic.buildAssistantMessage', () {
    test('builds message with text content', () {
      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: 'Hello!',
        thinking: '',
        toolCalls: {},
        isStreaming: false,
      );
      expect(msg.id, 'a-1');
      expect(msg.role, MessageRole.assistant);
      expect(msg.isStreaming, false);
      expect(msg.content.length, 1);
      expect(msg.content.first, isA<TextContentBlock>());
      expect((msg.content.first as TextContentBlock).text, 'Hello!');
    });

    test('includes thinking block when present', () {
      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: 'answer',
        thinking: 'let me think...',
        toolCalls: {},
        isStreaming: false,
      );
      expect(msg.content.length, 2);
      expect(msg.content[0], isA<ThinkingContentBlock>());
      expect(msg.content[1], isA<TextContentBlock>());
    });

    test('includes tool calls when present', () {
      final tc = ToolCallAccumulator()
        ..id = 'tc-1'
        ..name = 'search';
      tc.argumentsBuffer.write('{"q":"dart"}');

      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: '',
        thinking: '',
        toolCalls: {0: tc},
        isStreaming: false,
      );
      expect(msg.content.length, 1);
      expect(msg.content.first, isA<ToolCallContentBlock>());
      final block = msg.content.first as ToolCallContentBlock;
      expect(block.id, 'tc-1');
      expect(block.name, 'search');
      expect(block.arguments, '{"q":"dart"}');
    });

    test('skips invalid tool calls (missing id or name)', () {
      final tc = ToolCallAccumulator()..name = 'search';
      // id is null → invalid

      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: '',
        thinking: '',
        toolCalls: {0: tc},
        isStreaming: false,
      );
      // Should have empty text fallback since no valid blocks
      expect(msg.content.length, 1);
      expect(msg.content.first, isA<TextContentBlock>());
      expect((msg.content.first as TextContentBlock).text, '');
    });

    test('adds empty text block when everything is empty', () {
      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: '',
        thinking: '',
        toolCalls: {},
        isStreaming: false,
      );
      expect(msg.content.length, 1);
      expect((msg.content.first as TextContentBlock).text, '');
    });

    test('sets isStreaming flag', () {
      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: 'streaming...',
        thinking: '',
        toolCalls: {},
        isStreaming: true,
      );
      expect(msg.isStreaming, true);
    });
  });

  group('ChatLogic.buildApiMessages', () {
    test('adds system prompt when non-empty', () {
      final messages = logic.buildApiMessages(
        history: [],
        systemPrompt: 'You are helpful',
      );
      expect(messages.length, 1);
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'You are helpful');
    });

    test('skips system prompt when empty', () {
      final messages = logic.buildApiMessages(
        history: [],
        systemPrompt: '',
      );
      expect(messages, isEmpty);
    });

    test('converts user messages', () {
      final messages = logic.buildApiMessages(
        history: [
          Message(
            id: 'm-1',
            conversationId: 'c-1',
            role: MessageRole.user,
            content: [const ContentBlock.text(text: 'hi')],
            createdAt: DateTime.now(),
          ),
        ],
        systemPrompt: '',
      );
      expect(messages.length, 1);
      expect(messages.first['role'], 'user');
      expect(messages.first['content'], 'hi');
    });

    test('injects image_url user message for tool results with images', () {
      final messages = logic.buildApiMessages(
        history: [
          Message(
            id: 'm-1',
            conversationId: 'c-1',
            role: MessageRole.tool,
            content: [
              const ContentBlock.toolResult(
                toolCallId: 'tc-1',
                toolName: 'screenshot',
                resultContent: [
                  ContentBlock.text(text: 'captured'),
                  ContentBlock.image(
                    base64Data: 'imgdata',
                    mimeType: 'image/png',
                  ),
                ],
              ),
            ],
            createdAt: DateTime.now(),
          ),
        ],
        systemPrompt: '',
      );
      // Should have tool message + injected user message with image
      expect(messages.length, 2);
      expect(messages[0]['role'], 'tool');
      expect(messages[1]['role'], 'user');
      final userContent = messages[1]['content'] as List;
      expect(userContent.length, 2);
      expect(userContent[0]['type'], 'image_url');
      expect(
        (userContent[0]['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'),
      );
    });

    test('does not inject image for tool results without images', () {
      final messages = logic.buildApiMessages(
        history: [
          Message(
            id: 'm-1',
            conversationId: 'c-1',
            role: MessageRole.tool,
            content: [
              const ContentBlock.toolResult(
                toolCallId: 'tc-1',
                toolName: 'search',
                resultContent: [ContentBlock.text(text: 'results here')],
              ),
            ],
            createdAt: DateTime.now(),
          ),
        ],
        systemPrompt: '',
      );
      expect(messages.length, 1);
      expect(messages.first['role'], 'tool');
    });
  });

  group('ChatLogic.generateAutoTitle', () {
    test('returns first line when short', () {
      expect(logic.generateAutoTitle('Short title'), 'Short title');
    });

    test('truncates long first line to 50 chars', () {
      final longLine = 'A' * 100;
      final title = logic.generateAutoTitle(longLine);
      expect(title, '${'A' * 47}...');
      expect(title!.length, 50);
    });

    test('uses only first line of multiline response', () {
      expect(
        logic.generateAutoTitle('First line\nSecond line\nThird'),
        'First line',
      );
    });

    test('returns null for empty string', () {
      expect(logic.generateAutoTitle(''), isNull);
    });

    test('returns null for whitespace-only first line', () {
      expect(logic.generateAutoTitle('   \nactual content'), isNull);
    });
  });

  group('ToolCallAccumulator', () {
    test('isValid when both id and name are set', () {
      final tc = ToolCallAccumulator()
        ..id = 'tc-1'
        ..name = 'search';
      expect(tc.isValid, true);
    });

    test('isValid is false when id is null', () {
      final tc = ToolCallAccumulator()..name = 'search';
      expect(tc.isValid, false);
    });

    test('isValid is false when name is null', () {
      final tc = ToolCallAccumulator()..id = 'tc-1';
      expect(tc.isValid, false);
    });

    test('accumulates arguments', () {
      final tc = ToolCallAccumulator();
      tc.argumentsBuffer.write('{"q":');
      tc.argumentsBuffer.write('"test"}');
      expect(tc.argumentsBuffer.toString(), '{"q":"test"}');
    });
  });
}
