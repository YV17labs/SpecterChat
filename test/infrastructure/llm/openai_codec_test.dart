import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/infrastructure/llm/openai_codec.dart';

import '../../support/fakes.dart';

ImageBytesMap _bytes(String id) => {
  id: (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
};

const _png = ContentBlock.image(
  attachmentId: 'att-1',
  mimeType: 'image/png',
  byteSize: 3,
);

void main() {
  const codec = OpenAiCodec();

  group('messageToApi', () {
    test('plain user text collapses to a string content', () {
      final api = codec.messageToApi(
        testMessage(MessageRole.user, [const ContentBlock.text(text: 'hello')]),
        const {},
      );
      expect(api, {'role': 'user', 'content': 'hello'});
    });

    test('user text + resolved image becomes a parts array', () {
      final api = codec.messageToApi(
        testMessage(MessageRole.user, [
          const ContentBlock.text(text: 'look'),
          _png,
        ]),
        _bytes('att-1'),
      );
      final parts = (api['content'] as List).cast<Map<String, dynamic>>();
      expect(parts, hasLength(2));
      expect(parts[1]['type'], 'image_url');
      expect(
        (parts[1]['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'),
      );
    });

    test('unresolved image attachment is silently dropped', () {
      final api = codec.messageToApi(
        testMessage(MessageRole.user, [
          const ContentBlock.text(text: 'look'),
          _png,
        ]),
        const {},
      );
      expect(api['content'], 'look');
    });

    test('assistant tool calls go on tool_calls with empty args as {}', () {
      final api = codec.messageToApi(
        testMessage(MessageRole.assistant, [
          const ContentBlock.text(text: 'Let me search'),
          const ContentBlock.toolCall(
            id: 'tc-1',
            name: 'search',
            arguments: ' ',
          ),
        ]),
        const {},
      );
      expect(api['role'], 'assistant');
      expect(api['content'], 'Let me search');
      expect(api['tool_calls'], [
        {
          'id': 'tc-1',
          'type': 'function',
          'function': {'name': 'search', 'arguments': '{}'},
        },
      ]);
    });

    test('tool result carries only its text on the tool role', () {
      final api = codec.messageToApi(
        testMessage(MessageRole.tool, [
          const ContentBlock.toolResult(
            toolCallId: 'tc-1',
            toolName: 'search',
            resultContent: [
              ContentBlock.text(text: 'Found'),
              _png,
            ],
          ),
        ]),
        _bytes('att-1'),
      );
      expect(api, {'role': 'tool', 'tool_call_id': 'tc-1', 'content': 'Found'});
    });

    test('thinking blocks never reach the wire', () {
      final api = codec.messageToApi(
        testMessage(MessageRole.assistant, [
          const ContentBlock.thinking(text: 'hmm...'),
          const ContentBlock.text(text: 'answer'),
        ]),
        const {},
      );
      expect(api['content'], 'answer');
    });
  });

  group('buildMessages', () {
    test('prepends the system prompt only when non-empty', () {
      expect(codec.buildMessages(history: const [], systemPrompt: 'S'), [
        {'role': 'system', 'content': 'S'},
      ]);
      expect(codec.buildMessages(history: const [], systemPrompt: ''), isEmpty);
    });

    test(
      'images in tool results are re-injected as a user message after the run',
      () {
        final history = [
          testMessage(MessageRole.tool, [
            const ContentBlock.toolResult(
              toolCallId: 'tc-1',
              toolName: 'screenshot',
              resultContent: [
                ContentBlock.text(text: 'captured'),
                _png,
              ],
            ),
          ]),
          testMessage(MessageRole.tool, [
            const ContentBlock.toolResult(
              toolCallId: 'tc-2',
              toolName: 'other',
              resultContent: [ContentBlock.text(text: 'x')],
            ),
          ]),
          testMessage(MessageRole.assistant, [
            const ContentBlock.text(text: 'done'),
          ]),
        ];
        final messages = codec.buildMessages(
          history: history,
          systemPrompt: '',
          imageBytes: _bytes('att-1'),
        );
        expect(messages.map((m) => m['role']), [
          'tool',
          'tool',
          'user',
          'assistant',
        ]);
        final parts = (messages[2]['content'] as List)
            .cast<Map<String, dynamic>>();
        expect(parts[0]['type'], 'image_url');
        expect(parts[1]['text'], 'Image result from tool "screenshot".');
      },
    );

    test('no image injection when tool results have no images', () {
      final messages = codec.buildMessages(
        history: [
          testMessage(MessageRole.tool, [
            const ContentBlock.toolResult(
              toolCallId: 'tc-1',
              toolName: 'search',
              resultContent: [ContentBlock.text(text: 'results')],
            ),
          ]),
        ],
        systemPrompt: '',
      );
      expect(messages.map((m) => m['role']), ['tool']);
    });

    test(
      'assistant turns with unparseable tool args are skipped with their results',
      () {
        final history = [
          testMessage(MessageRole.user, [const ContentBlock.text(text: 'q')]),
          testMessage(MessageRole.assistant, [
            const ContentBlock.toolCall(
              id: 'tc',
              name: 'search',
              arguments: '{"q":',
            ),
          ]),
          testMessage(MessageRole.tool, [
            const ContentBlock.toolResult(toolCallId: 'tc', toolName: 'search'),
          ]),
          testMessage(MessageRole.assistant, [
            const ContentBlock.text(text: 'ok'),
          ]),
        ];
        final messages = codec.buildMessages(
          history: history,
          systemPrompt: '',
        );
        expect(messages.map((m) => m['role']), ['user', 'assistant']);
        expect(messages.last['content'], 'ok');
      },
    );
  });

  group('toolsToApi', () {
    test('maps every tool it is given — filtering happens upstream', () {
      const tools = [
        McpToolInfo(
          name: 'search',
          description: 'Search',
          inputSchema: {'type': 'object'},
        ),
      ];
      expect(codec.toolsToApi(tools), [
        {
          'type': 'function',
          'function': {
            'name': 'search',
            'description': 'Search',
            'parameters': {'type': 'object'},
          },
        },
      ]);
      expect(codec.toolsToApi(const []), isEmpty);
    });
  });
}
