import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/chat_logic.dart';
import 'package:specterchat/application/chat/message_writes.dart';
import 'package:specterchat/application/chat/stream_accumulator.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/domain/services/llm_hook.dart';

import '../../support/fakes.dart';

class _XmlHook implements LlmHook {
  @override
  RegExp get modelPattern => RegExp('.*');

  @override
  bool detectHallucination(String text) => text.contains('<tool_call>');

  @override
  String get hallucinationCorrection => '$correctionPrefix — retry';
}

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
      expect(msg.content, [const ContentBlock.text(text: 'Hello!')]);
    });

    test('includes thinking block before text', () {
      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: 'answer',
        thinking: 'let me think...',
        toolCalls: {},
        isStreaming: false,
      );
      expect(msg.content, [
        const ContentBlock.thinking(text: 'let me think...'),
        const ContentBlock.text(text: 'answer'),
      ]);
    });

    test('includes valid tool calls and skips incomplete ones', () {
      final valid = ToolCallAccumulator()
        ..id = 'tc-1'
        ..name = 'search';
      valid.argumentsBuffer.write('{"q":"dart"}');
      final noId = ToolCallAccumulator()..name = 'search';

      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: '',
        thinking: '',
        toolCalls: {0: valid, 1: noId},
        isStreaming: false,
      );
      expect(msg.content, [
        const ContentBlock.toolCall(
          id: 'tc-1',
          name: 'search',
          arguments: '{"q":"dart"}',
        ),
      ]);
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
      expect(msg.content, [const ContentBlock.text(text: '')]);
    });

    test('propagates streaming flag, tokens and duration', () {
      final msg = logic.buildAssistantMessage(
        id: 'a-1',
        conversationId: 'c-1',
        content: 'x',
        thinking: '',
        toolCalls: {},
        isStreaming: true,
        completionTokens: 12,
        durationMs: 340,
      );
      expect(msg.isStreaming, true);
      expect(msg.completionTokens, 12);
      expect(msg.durationMs, 340);
    });
  });

  group('ChatLogic.buildUserMessage', () {
    test('text only', () {
      final msg = logic.buildUserMessage(
        id: 'u',
        conversationId: 'c',
        text: 'hello',
      );
      expect(msg.id, 'u');
      expect(msg.conversationId, 'c');
      expect(msg.role, MessageRole.user);
      expect(msg.content, [const ContentBlock.text(text: 'hello')]);
      expect(msg.isStreaming, isFalse);
    });

    test('text then one image block per attachment, sizes from bytes', () {
      final msg = logic.buildUserMessage(
        id: 'u',
        conversationId: 'c',
        text: 'look',
        images: [
          PendingAttachment(
            attachmentId: 'a1',
            bytes: Uint8List(3),
            mimeType: 'image/png',
          ),
          PendingAttachment(
            attachmentId: 'a2',
            bytes: Uint8List(5),
            mimeType: 'image/jpeg',
          ),
        ],
      );
      expect(msg.content, [
        const ContentBlock.text(text: 'look'),
        const ContentBlock.image(
          attachmentId: 'a1',
          mimeType: 'image/png',
          byteSize: 3,
        ),
        const ContentBlock.image(
          attachmentId: 'a2',
          mimeType: 'image/jpeg',
          byteSize: 5,
        ),
      ]);
    });

    test('an image-only turn has no empty text block', () {
      final msg = logic.buildUserMessage(
        id: 'u',
        conversationId: 'c',
        text: '',
        images: [
          PendingAttachment(
            attachmentId: 'a1',
            bytes: Uint8List(1),
            mimeType: 'image/png',
          ),
        ],
      );
      expect(msg.content.whereType<TextContentBlock>(), isEmpty);
      expect(msg.content, hasLength(1));
    });
  });

  group('ChatLogic.analyzeCompletion', () {
    StreamAccumulator turn({
      String content = '',
      String thinking = '',
      bool toolCall = false,
    }) {
      final acc = StreamAccumulator();
      if (content.isNotEmpty) acc.addContent(content);
      if (thinking.isNotEmpty) acc.addThinking(thinking);
      if (toolCall) {
        acc.addToolCallDelta(
          const ToolCallDelta(
            index: 0,
            id: 'tc',
            name: 'search',
            argumentsDelta: '{}',
          ),
        );
      }
      return acc;
    }

    test('plain text without a hook is kept and needs nothing else', () {
      final a = logic.analyzeCompletion(turn(content: 'hi'));
      expect(a.keepMessage, isTrue);
      expect(a.shouldRunTools, isFalse);
      expect(a.shouldRetry, isFalse);
    });

    test('valid tool calls run tools', () {
      final a = logic.analyzeCompletion(turn(toolCall: true));
      expect(a.keepMessage, isTrue);
      expect(a.shouldRunTools, isTrue);
    });

    test('hallucinated XML in content is dropped and retried', () {
      final a = logic.analyzeCompletion(
        turn(content: '<tool_call>search</tool_call>', toolCall: true),
        hook: _XmlHook(),
      );
      expect(a.hallucinated, isTrue);
      expect(a.keepMessage, isFalse);
      expect(a.shouldRunTools, isFalse);
      expect(a.shouldRetry, isTrue);
    });

    test('hallucination is also detected in thinking', () {
      final a = logic.analyzeCompletion(
        turn(content: 'ok', thinking: 'I will emit <tool_call>'),
        hook: _XmlHook(),
      );
      expect(a.hallucinated, isTrue);
    });

    test('empty turn with thinking counts as suppressed when hooked', () {
      final a = logic.analyzeCompletion(
        turn(thinking: 'thought hard'),
        hook: _XmlHook(),
      );
      expect(a.suppressed, isTrue);
      expect(a.shouldRetry, isTrue);
      expect(a.keepMessage, isFalse);
    });

    test('empty turn with thinking is not suppressed without a hook', () {
      final a = logic.analyzeCompletion(turn(thinking: 'thought hard'));
      expect(a.suppressed, isFalse);
      expect(a.shouldRetry, isFalse);
    });
  });

  group('ChatLogic.collectImageAttachmentIds', () {
    test('collects and de-duplicates ids across messages', () {
      Message msg(String id, List<ContentBlock> content) =>
          testMessage(MessageRole.tool, content, id: id);
      const img = ContentBlock.image(
        attachmentId: 'a',
        mimeType: 'image/png',
        byteSize: 1,
      );
      final ids = logic.collectImageAttachmentIds([
        msg('1', [img]),
        msg('2', [
          const ContentBlock.toolResult(
            toolCallId: 't',
            toolName: 'shot',
            resultContent: [
              img,
              ContentBlock.image(
                attachmentId: 'b',
                mimeType: 'image/png',
                byteSize: 1,
              ),
            ],
          ),
        ]),
      ]);
      expect(ids, {'a', 'b'});
    });
  });

  group('ChatLogic.generateAutoTitle', () {
    test('returns first line when short', () {
      expect(logic.generateAutoTitle('Short title'), 'Short title');
    });

    test('truncates long first line to 50 chars', () {
      final title = logic.generateAutoTitle('A' * 100);
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
}
