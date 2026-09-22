import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/message.dart';

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
        final json =
            jsonDecode(jsonEncode(block.toJson())) as Map<String, dynamic>;
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
      final json = jsonDecode(jsonEncode(msg.toJson())) as Map<String, dynamic>;
      final restored = Message.fromJson(json);
      expect(restored.id, msg.id);
      expect(restored.role, msg.role);
      expect(restored.content.length, 2);
    });
  });

  group('MessageContentX', () {
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

  group('plainText', () {
    test('joins text blocks and ignores the rest', () {
      final msg = Message(
        id: 'm',
        conversationId: 'c',
        role: MessageRole.assistant,
        content: [
          const ContentBlock.thinking(text: 'x'),
          const ContentBlock.text(text: 'a'),
          const ContentBlock.text(text: 'b'),
        ],
        createdAt: DateTime(2024),
      );
      expect(msg.plainText, 'ab');
    });
  });

  group('hasParseableToolCallArgs', () {
    test('accepts empty, whitespace and valid JSON', () {
      expect(hasParseableToolCallArgs(''), isTrue);
      expect(hasParseableToolCallArgs('  '), isTrue);
      expect(hasParseableToolCallArgs('{"q":"x"}'), isTrue);
    });

    test('rejects truncated JSON', () {
      expect(hasParseableToolCallArgs('{"q":'), isFalse);
    });
  });

  group('what a message weighs', () {
    Message of(List<ContentBlock> content) => Message(
      id: 'm',
      conversationId: 'c',
      role: MessageRole.user,
      content: content,
      createdAt: DateTime(2024),
    );

    test('adds the images as stored to the text as UTF-8', () {
      final message = of(const [
        ContentBlock.text(text: 'abc'),
        ContentBlock.image(
          attachmentId: 'a',
          mimeType: 'image/png',
          byteSize: 1400000,
        ),
      ]);
      expect(message.contentBytes, 1400003);
      expect(message.hasImages, isTrue);
    });

    test('counts a character by what it takes, not by what it looks', () {
      // 'é' is two bytes, '🖼' four — a text message is not its length.
      expect(of(const [ContentBlock.text(text: 'é🖼')]).contentBytes, 6);
    });

    test('a tool result weighs its own content, not its raw response', () {
      final message = of(const [
        ContentBlock.toolResult(
          toolCallId: 'tc-1',
          toolName: 'screen_shot',
          resultContent: [
            ContentBlock.text(text: 'ok'),
            ContentBlock.image(
              attachmentId: 'a',
              mimeType: 'image/png',
              byteSize: 820000,
            ),
          ],
          rawResponse: '{"content":[{"type":"image","data":"attachment:a"}]}',
        ),
      ]);
      expect(message.contentBytes, 820002);
      expect(message.hasImages, isTrue);
    });

    test('a text-only message has no picture to weigh', () {
      expect(of(const [ContentBlock.text(text: 'hello')]).hasImages, isFalse);
    });
  });
}
