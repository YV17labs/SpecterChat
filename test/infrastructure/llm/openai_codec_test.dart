import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/model_info.dart';
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
  _imageModelTests();

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

    test('assistant image blocks are re-sent as image_url parts', () {
      // Iterative editing: "now make the sky blue" must carry the image
      // the assistant produced on the previous turn.
      final api = codec.messageToApi(
        testMessage(MessageRole.assistant, [
          const ContentBlock.text(text: 'Here it is'),
          _png,
        ]),
        _bytes('att-1'),
      );
      expect(api['role'], 'assistant');
      final parts = (api['content'] as List).cast<Map<String, dynamic>>();
      expect(parts.map((p) => p['type']), ['text', 'image_url']);
      expect(
        (parts[1]['image_url'] as Map)['url'],
        'data:image/png;base64,AQID',
      );
    });

    test('image-only assistant message is a single image_url part', () {
      final api = codec.messageToApi(
        testMessage(MessageRole.assistant, [_png]),
        _bytes('att-1'),
      );
      final parts = (api['content'] as List).cast<Map<String, dynamic>>();
      expect(parts.single['type'], 'image_url');
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

  group('decodeDataUrl', () {
    test('round-trips imageUrlPart', () {
      final part = codec.imageUrlPart((
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/webp',
      ));
      final decoded = OpenAiCodec.decodeDataUrl(
        (part['image_url'] as Map)['url'] as String,
      );
      expect(decoded, isNotNull);
      expect(decoded!.mimeType, 'image/webp');
      expect(decoded.bytes, [1, 2, 3]);
    });

    test('rejects http URLs, non-base64 and malformed payloads', () {
      expect(OpenAiCodec.decodeDataUrl('https://x/y.png'), isNull);
      expect(OpenAiCodec.decodeDataUrl('data:image/png,plain'), isNull);
      expect(OpenAiCodec.decodeDataUrl('data:image/png;base64,***'), isNull);
      expect(OpenAiCodec.decodeDataUrl('data:;base64,AQID'), isNull);
    });

    test('tolerates trailing whitespace without copying the payload', () {
      final decoded = OpenAiCodec.decodeDataUrl('data:image/png;base64,AQID\n');
      expect(decoded?.bytes, [1, 2, 3]);
    });
  });

  group('generatedImages', () {
    test('extracts the URLs of an OpenRouter images array', () {
      final images = OpenAiCodec.generatedImages([
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,AQID'},
          'generation': {'seed': 42},
        },
        {'type': 'image_url', 'url': 'https://x/y.png'}, // flat variant
        {'type': 'image_url'}, // no url → dropped
        'garbage',
      ]);
      expect(images.map((i) => i.url), [
        'data:image/png;base64,AQID',
        'https://x/y.png',
      ]);
    });

    test('reads what the server says it generated from', () {
      Map<String, Object> entry(Object? meta) => {
        'type': 'image_url',
        'image_url': {'url': 'https://x/y.png'},
        'generation': ?meta,
      };
      final images = OpenAiCodec.generatedImages([
        entry({'mode': 'reference_edit'}),
        entry({'mode': 'text_to_image'}),
        entry({'seed': 1}),
        entry(null),
        {
          'image_url': {'url': 'https://x/old.png'},
          'specterforge': {'mode': 'reference_edit'}, // pre-0.3.0 key
        },
      ]);
      expect(images.map((i) => i.textToImage), [
        false,
        true,
        null,
        null,
        false,
      ]);
    });

    test('is empty for anything that is not a list', () {
      expect(OpenAiCodec.generatedImages(null), isEmpty);
      expect(OpenAiCodec.generatedImages('x'), isEmpty);
    });
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

    test("inlines the schema's local refs before the model sees it", () {
      const tools = [
        McpToolInfo(
          name: 'screen_shot',
          description: 'Capture',
          inputSchema: {
            r'$defs': {
              'RegionDto': {'type': 'object'},
            },
            'type': 'object',
            'properties': {
              'region': {
                'anyOf': [
                  {r'$ref': r'#/$defs/RegionDto'},
                  {'type': 'null'},
                ],
              },
            },
          },
        ),
      ];
      final function = codec.toolsToApi(tools).single['function'] as Map;
      expect(function['parameters'], {
        'type': 'object',
        'properties': {
          'region': {
            'anyOf': [
              {'type': 'object'},
              {'type': 'null'},
            ],
          },
        },
      });
    });
  });
}

void _imageModelTests() {
  const codec = OpenAiCodec();

  group('parseModelInfo', () {
    test('plain entry is a text model', () {
      final m = OpenAiCodec.parseModelInfo(const {'id': 'gpt-x'});
      expect(m.id, 'gpt-x');
      expect(m.isImage, isFalse);
    });

    test('generation kind=image yields capabilities and defaults', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'qwen-image-2.1',
        'generation': {
          'kind': 'image',
          'backend': 'torch',
          'device': 'mps',
          'capabilities': {
            'text_to_image': true,
            'reference_edit': true,
            'max_reference_images': 10,
            'rgba': true,
            'max_side': 2048,
            'img2img': true, // unknown keys from older servers are ignored
          },
          'defaults': {
            'steps': 20,
            'max_steps': 100,
            'base_size': 1024,
            'base_sizes': [768, 1024, 1536, 2048],
            'aspect_ratios': ['1:1', '16:9'],
            'guidance': 1.0,
            'brain': true,
          },
          'pool': {'backends': <Object>[]},
        },
      });
      final image = m.image!;
      expect(image.backend, 'torch');
      expect(image.device, 'mps');
      expect(image.capabilities.referenceEdit, isTrue);
      expect(image.capabilities.maxReferenceImages, 10);
      expect(image.capabilities.rgba, isTrue);
      expect(image.capabilities.maxSide, 2048);
      expect(image.defaults.steps, 20);
      expect(image.defaults.aspectRatios, ['1:1', '16:9']);
    });

    test('image model without defaults/capabilities gets built-in ones', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'img',
        'generation': {'kind': 'image'},
      });
      expect(m.image!.defaults, const ImageDefaults());
      expect(m.image!.capabilities, const ImageCapabilities());
    });

    test('pre-0.3 servers tagging with `specterforge` are still image', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'img',
        'specterforge': {'kind': 'image', 'backend': 'mlx'},
      });
      expect(m.isImage, isTrue);
      expect(m.image!.backend, 'mlx');
    });

    test('`generation` wins over a stale `specterforge` block', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'img',
        'generation': {'kind': 'image', 'backend': 'torch'},
        'specterforge': {'kind': 'image', 'backend': 'mlx'},
      });
      expect(m.image!.backend, 'torch');
    });

    test('other kinds and malformed extension blocks are text models', () {
      expect(
        OpenAiCodec.parseModelInfo(const {
          'id': 'a',
          'generation': {'kind': 'audio'},
        }).isImage,
        isFalse,
      );
      expect(
        OpenAiCodec.parseModelInfo(const {
          'id': 'b',
          'generation': 'nope',
        }).isImage,
        isFalse,
      );
    });

    test('entry without id is rejected', () {
      expect(
        () => OpenAiCodec.parseModelInfo(const {'object': 'model'}),
        throwsFormatException,
      );
    });
  });

  group('imageOptionsToApi', () {
    test('only overridden fields, snake_case, mode auto omitted', () {
      expect(codec.imageOptionsToApi(const ImageSettings()), isEmpty);
      expect(
        codec.imageOptionsToApi(const ImageSettings(mode: ImageMode.auto)),
        isEmpty,
      );
      expect(
        codec.imageOptionsToApi(
          const ImageSettings(
            mode: ImageMode.edit,
            baseSize: 768,
            aspectRatio: '9:16',
            steps: 8,
            seed: 7,
            guidance: 2.5,
            negativePrompt: 'text',
            transparent: true,
          ),
        ),
        {
          'mode': 'edit',
          'base_size': 768,
          'aspect_ratio': '9:16',
          'steps': 8,
          'seed': 7,
          'guidance': 2.5,
          'negative_prompt': 'text',
          'transparent': true,
        },
      );
    });

    test('empty negative prompt is not sent', () {
      expect(
        codec.imageOptionsToApi(const ImageSettings(negativePrompt: '')),
        isEmpty,
      );
    });
  });
}
