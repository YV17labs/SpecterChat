import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/models/message.dart';

void main() {
  group('ContentBlock', () {
    group('text', () {
      test('creates with required text', () {
        const block = ContentBlock.text(text: 'hello');
        expect(block, isA<TextContentBlock>());
        expect((block as TextContentBlock).text, 'hello');
      });

      test('roundtrips through JSON', () {
        const block = ContentBlock.text(text: 'hello world');
        final json = block.toJson();
        final restored = ContentBlock.fromJson(json);
        expect(restored, block);
      });
    });

    group('image', () {
      test('creates with attachment id, mime type, and byte size', () {
        const block = ContentBlock.image(
          attachmentId: 'att-1',
          mimeType: 'image/png',
          byteSize: 1234,
        );
        expect(block, isA<ImageContentBlock>());
        const img = block as ImageContentBlock;
        expect(img.attachmentId, 'att-1');
        expect(img.mimeType, 'image/png');
        expect(img.byteSize, 1234);
      });

      test('roundtrips through JSON', () {
        const block = ContentBlock.image(
          attachmentId: 'att-1',
          mimeType: 'image/jpeg',
          byteSize: 42,
        );
        final json = block.toJson();
        final restored = ContentBlock.fromJson(json);
        expect(restored, block);
      });
    });

    group('toolCall', () {
      test('creates with id, name, and arguments', () {
        const block = ContentBlock.toolCall(
          id: 'tc-1',
          name: 'search',
          arguments: '{"q":"test"}',
        );
        expect(block, isA<ToolCallContentBlock>());
        const tc = block as ToolCallContentBlock;
        expect(tc.id, 'tc-1');
        expect(tc.name, 'search');
        expect(tc.arguments, '{"q":"test"}');
      });

      test('roundtrips through JSON', () {
        const block = ContentBlock.toolCall(
          id: 'tc-1',
          name: 'search',
          arguments: '{"q":"test"}',
        );
        final json = block.toJson();
        final restored = ContentBlock.fromJson(json);
        expect(restored, block);
      });
    });

    group('toolResult', () {
      test('creates with required fields', () {
        const block = ContentBlock.toolResult(
          toolCallId: 'tc-1',
          toolName: 'search',
          resultContent: [ContentBlock.text(text: 'result text')],
        );
        const tr = block as ToolResultContentBlock;
        expect(tr.toolCallId, 'tc-1');
        expect(tr.resultContent.whereType<ImageContentBlock>(), isEmpty);
      });

      test('creates with optional image', () {
        const block = ContentBlock.toolResult(
          toolCallId: 'tc-1',
          toolName: 'screenshot',
          resultContent: [
            ContentBlock.image(
              attachmentId: 'att-1',
              mimeType: 'image/png',
              byteSize: 100,
            ),
          ],
        );
        const tr = block as ToolResultContentBlock;
        final image = tr.resultContent.whereType<ImageContentBlock>().single;
        expect(image.attachmentId, 'att-1');
        expect(image.mimeType, 'image/png');
      });

      test('roundtrips through JSON', () {
        const block = ContentBlock.toolResult(
          toolCallId: 'tc-1',
          toolName: 'search',
          resultContent: [
            ContentBlock.text(text: 'found it'),
            ContentBlock.image(
              attachmentId: 'att-1',
              mimeType: 'image/png',
              byteSize: 50,
            ),
          ],
        );
        final json = jsonDecode(jsonEncode(block.toJson()))
            as Map<String, dynamic>;
        final restored = ContentBlock.fromJson(json);
        expect(restored, block);
      });
    });

    group('thinking', () {
      test('creates and roundtrips', () {
        const block = ContentBlock.thinking(text: 'let me think...');
        expect(block, isA<ThinkingContentBlock>());
        final json = block.toJson();
        final restored = ContentBlock.fromJson(json);
        expect(restored, block);
      });
    });
  });

  group('Message', () {
    test('creates with all required fields', () {
      final now = DateTime.now();
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        content: [const ContentBlock.text(text: 'hi')],
        createdAt: now,
      );
      expect(msg.id, 'msg-1');
      expect(msg.role, MessageRole.user);
      expect(msg.isStreaming, false);
    });

    test('isStreaming defaults to false', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.assistant,
        content: [const ContentBlock.text(text: 'hi')],
        createdAt: DateTime.now(),
      );
      expect(msg.isStreaming, false);
    });

    test('copyWith works', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        content: [const ContentBlock.text(text: 'hi')],
        createdAt: DateTime.now(),
      );
      final streaming = msg.copyWith(isStreaming: true);
      expect(streaming.isStreaming, true);
      expect(streaming.id, 'msg-1');
    });

    test('roundtrips through JSON', () {
      final now = DateTime.now();
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        content: [
          const ContentBlock.text(text: 'hello'),
          const ContentBlock.image(
            attachmentId: 'att-1',
            mimeType: 'image/png',
            byteSize: 10,
          ),
        ],
        createdAt: now,
      );
      final json = jsonDecode(jsonEncode(msg.toJson()))
          as Map<String, dynamic>;
      final restored = Message.fromJson(json);
      expect(restored.id, msg.id);
      expect(restored.role, msg.role);
      expect(restored.content.length, 2);
    });
  });

  group('MessageToApi', () {
    final emptyBytes = <String, ImageBytes>{};

    ImageBytesMap bytesFor(String id, List<int> bytes, String mime) => {
          id: (bytes: Uint8List.fromList(bytes), mimeType: mime),
        };

    test('simple user text message', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        content: [const ContentBlock.text(text: 'hello')],
        createdAt: DateTime.now(),
      );
      final api = msg.toApiMessage(emptyBytes);
      expect(api['role'], 'user');
      expect(api['content'], 'hello');
    });

    test('user message with image uses array content when bytes resolved', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        content: [
          const ContentBlock.text(text: 'look'),
          const ContentBlock.image(
            attachmentId: 'att-1',
            mimeType: 'image/png',
            byteSize: 3,
          ),
        ],
        createdAt: DateTime.now(),
      );
      final api = msg.toApiMessage(bytesFor('att-1', [1, 2, 3], 'image/png'));
      expect(api['content'], isList);
      expect((api['content'] as List).length, 2);
      final imagePart = (api['content'] as List)[1];
      expect(imagePart['type'], 'image_url');
      expect(imagePart['image_url']['url'], startsWith('data:image/png;base64,'));
    });

    test('unresolved image attachment is silently dropped', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        content: [
          const ContentBlock.text(text: 'look'),
          const ContentBlock.image(
            attachmentId: 'missing',
            mimeType: 'image/png',
            byteSize: 3,
          ),
        ],
        createdAt: DateTime.now(),
      );
      final api = msg.toApiMessage(emptyBytes);
      expect(api['content'], 'look');
    });

    test('assistant message with tool calls', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.assistant,
        content: [
          const ContentBlock.text(text: 'Let me search'),
          const ContentBlock.toolCall(
            id: 'tc-1',
            name: 'search',
            arguments: '{"q":"dart"}',
          ),
        ],
        createdAt: DateTime.now(),
      );
      final api = msg.toApiMessage(emptyBytes);
      expect(api['role'], 'assistant');
      expect(api['tool_calls'], isList);
      expect((api['tool_calls'] as List).length, 1);
      final tc = (api['tool_calls'] as List).first;
      expect(tc['id'], 'tc-1');
      expect(tc['function']['name'], 'search');
    });

    test('tool result message', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.tool,
        content: [
          const ContentBlock.toolResult(
            toolCallId: 'tc-1',
            toolName: 'search',
            resultContent: [ContentBlock.text(text: 'Found results')],
          ),
        ],
        createdAt: DateTime.now(),
      );
      final api = msg.toApiMessage(emptyBytes);
      expect(api['role'], 'tool');
      expect(api['tool_call_id'], 'tc-1');
      expect(api['content'], 'Found results');
    });

    test('thinking blocks are excluded from API content', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.assistant,
        content: [
          const ContentBlock.thinking(text: 'hmm...'),
          const ContentBlock.text(text: 'Here is the answer'),
        ],
        createdAt: DateTime.now(),
      );
      final apiContent = msg.toApiContent(emptyBytes);
      expect(apiContent.length, 1);
      expect(apiContent.first['text'], 'Here is the answer');
    });

    test('imageAttachmentIds collects from content and tool results', () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.tool,
        content: [
          const ContentBlock.toolResult(
            toolCallId: 'tc-1',
            toolName: 'screenshot',
            resultContent: [
              ContentBlock.image(
                attachmentId: 'att-a',
                mimeType: 'image/png',
                byteSize: 1,
              ),
              ContentBlock.text(text: 'caption'),
              ContentBlock.image(
                attachmentId: 'att-b',
                mimeType: 'image/png',
                byteSize: 1,
              ),
            ],
          ),
        ],
        createdAt: DateTime.now(),
      );
      expect(msg.imageAttachmentIds(), ['att-a', 'att-b']);
    });
  });
}
