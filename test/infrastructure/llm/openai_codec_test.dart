import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/domain/models/request_profile.dart';
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
      // What the image server reads back to edit what it made; for a text
      // model buildMessages takes them off the message first.
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

    test('a message left with no part carries an empty string, not []', () {
      // A message whose only attachment no longer resolves.
      expect(
        codec.messageToApi(testMessage(MessageRole.user, [_png]), const {}),
        {'role': 'user', 'content': ''},
      );
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

    test('an assistant image follows its turn in a user message', () {
      final messages = codec.buildMessages(
        history: [
          testMessage(MessageRole.user, [
            const ContentBlock.text(text: 'draw a cat'),
          ]),
          testMessage(MessageRole.assistant, [
            const ContentBlock.text(text: 'Here it is'),
            _png,
          ]),
        ],
        systemPrompt: '',
        imageBytes: _bytes('att-1'),
      );
      expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
      expect(messages[1]['content'], 'Here it is');
      final parts = (messages[2]['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(parts[0]['type'], 'image_url');
      expect(
        parts[1]['text'],
        'Image generated by the assistant on the turn above.',
      );
    });

    test('inline placement leaves the image on the assistant message', () {
      final messages = codec.buildMessages(
        history: [
          testMessage(MessageRole.assistant, [
            const ContentBlock.text(text: 'Here it is'),
            _png,
          ]),
        ],
        systemPrompt: '',
        imageBytes: _bytes('att-1'),
        assistantImages: AssistantImagePlacement.inline,
      );
      expect(messages.map((m) => m['role']), ['assistant']);
      final parts = (messages.single['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(parts.last['type'], 'image_url');
    });

    test('an image-only assistant turn is left with an empty content', () {
      final messages = codec.buildMessages(
        history: [
          testMessage(MessageRole.assistant, [_png]),
        ],
        systemPrompt: '',
        imageBytes: _bytes('att-1'),
      );
      expect(messages.first, {'role': 'assistant', 'content': ''});
      expect(messages.last['role'], 'user');
    });

    test(
      'a tool-calling turn holds its image back until the results are in',
      () {
        // Nothing may come between a tool_calls message and the tool
        // messages that answer it.
        final messages = codec.buildMessages(
          history: [
            testMessage(MessageRole.assistant, [
              const ContentBlock.text(text: 'looking'),
              const ContentBlock.toolCall(
                id: 'tc-1',
                name: 'search',
                arguments: '{}',
              ),
              _png,
            ]),
            testMessage(MessageRole.tool, [
              const ContentBlock.toolResult(
                toolCallId: 'tc-1',
                toolName: 'search',
                resultContent: [ContentBlock.text(text: 'found')],
              ),
            ]),
          ],
          systemPrompt: '',
          imageBytes: _bytes('att-1'),
        );
        expect(messages.map((m) => m['role']), ['assistant', 'tool', 'user']);
        expect(messages[0].containsKey('tool_calls'), isTrue);
        final parts = (messages[2]['content'] as List)
            .cast<Map<String, dynamic>>();
        expect(parts[0]['type'], 'image_url');
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

    test('a tool call left unanswered takes its turn out too', () {
      // The app was stopped, or died, between the call and its result.
      final history = [
        testMessage(MessageRole.user, [const ContentBlock.text(text: 'q')]),
        testMessage(MessageRole.assistant, [
          const ContentBlock.toolCall(id: 'a', name: 'search', arguments: '{}'),
          const ContentBlock.toolCall(id: 'b', name: 'shot', arguments: '{}'),
        ]),
        testMessage(MessageRole.tool, [
          const ContentBlock.toolResult(toolCallId: 'a', toolName: 'search'),
        ]),
        testMessage(MessageRole.user, [const ContentBlock.text(text: 'again')]),
      ];
      final messages = codec.buildMessages(history: history, systemPrompt: '');
      expect(messages.map((m) => m['role']), ['user', 'user']);
    });
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
      expect(image.api, ImageApi.chatGeneration);
      expect(image.backend, 'torch');
      expect(image.device, 'mps');
      expect(image.capabilities.referenceEdit, isTrue);
      expect(image.capabilities.maxReferenceImages, 10);
      expect(image.capabilities.rgba, isTrue);
      expect(image.capabilities.maxSide, 2048);
      expect(image.defaults.steps, 20);
      expect(image.defaults.aspectRatios, ['1:1', '16:9']);
    });

    test("a fixed schedule and the authors' recommendations are read", () {
      // Pictor 0.3 serving Qwen-Image-2.1-Turbo.
      final turbo = OpenAiCodec.parseModelInfo(const {
        'id': 'qwen-image-2.1-turbo',
        'generation': {
          'kind': 'image',
          'capabilities': {'fixed_steps': 8, 'max_side': 2752},
          'defaults': {'steps': 8, 'guidance': 1.0, 'base_size': 2048},
          'recommended': {
            'steps': 8,
            'guidance': 1.0,
            'base_size': 2048,
            'sizes': {
              '16:9': [2752, 1536],
            },
          },
        },
      }).image!;
      expect(turbo.capabilities.fixedSteps, 8);
      expect(
        turbo.recommended,
        const ImageRecommendations(steps: 8, guidance: 1.0, baseSize: 2048),
      );

      // The base model: no fixed schedule; nothing recommended may be null.
      final base = OpenAiCodec.parseModelInfo(const {
        'id': 'qwen-image-2.1',
        'generation': {
          'kind': 'image',
          'capabilities': {'fixed_steps': null},
          'recommended': {'steps': 40, 'guidance': null, 'base_size': null},
        },
      }).image!;
      expect(base.capabilities.fixedSteps, isNull);
      expect(base.recommended, const ImageRecommendations(steps: 40));
    });

    test('image model without defaults/capabilities gets built-in ones', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'img',
        'generation': {'kind': 'image'},
      });
      expect(m.image!.defaults, const ImageDefaults());
      expect(m.image!.capabilities, const ImageCapabilities());
      expect(m.image!.recommended, const ImageRecommendations());
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

    // As mlx-serve 26.10.1 lists Qwen-Image-2.1.
    test('`image` capability is an Images API model', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'ddalcu/Qwen-Image-2.1-Turbo-MLX-Serve-4bit',
        'object': 'model',
        'owned_by': 'mlx-serve',
        'context_length': 0,
        'capabilities': ['image'],
        'meta': {'architecture': 'qwen_image21', 'engine': 'mlx'},
      });
      // Nothing said per model: everything the API takes is offered, no
      // default is invented.
      expect(
        m.image,
        const ImageModelInfo(
          api: ImageApi.imagesEndpoint,
          capabilities: ImageCapabilities(referenceEdit: true, rgba: true),
        ),
      );
      expect(m.image!.defaults.steps, isNull);
      expect(m.image!.defaults.guidance, isNull);
      expect(m.image!.canChat, isFalse);
    });

    test('`vision` capability reads images, it does not make them', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'qwen3-vl',
        'capabilities': ['chat', 'tool_use', 'streaming', 'vision'],
      });
      expect(m.isImage, isFalse);
    });

    // OpenRouter's convention. A chat LLM that can also draw keeps its
    // system prompt, tools and sampling: it is not an image server.
    test('an image output modality leaves a chat model a chat model', () {
      final m = OpenAiCodec.parseModelInfo(const {
        'id': 'google/gemini-2.5-flash-image',
        'architecture': {
          'input_modalities': ['image', 'text'],
          'output_modalities': ['image', 'text'],
        },
      });
      expect(m.isImage, isFalse);
    });

    test('the most specific signal decides how the model is asked', () {
      expect(
        OpenAiCodec.parseModelInfo(const {
          'id': 'pictor',
          'generation': {'kind': 'image', 'backend': 'torch'},
          'capabilities': ['image'],
        }).image!.api,
        ImageApi.chatGeneration,
      );
      expect(
        OpenAiCodec.parseModelInfo(const {
          'id': 'mlx-serve',
          'capabilities': ['image'],
        }).image!.api,
        ImageApi.imagesEndpoint,
      );
    });

    test('capabilities of another shape are ignored', () {
      expect(
        OpenAiCodec.parseModelInfo(const {
          'id': 'a',
          'capabilities': {'vision': true, 'image': true},
        }).isImage,
        isFalse,
      );
      expect(
        OpenAiCodec.parseModelInfo(const {
          'id': 'b',
          'capabilities': 'image',
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

  group('imagesRequestBody', () {
    ContentBlock text(String t) => ContentBlock.text(text: t);
    ContentBlock image(String id) => ContentBlock.image(
      attachmentId: id,
      mimeType: 'image/png',
      byteSize: 1,
    );
    // Each id's bytes are its index + 1, so a base64 says which image it is.
    ImageBytesMap bytesOf(List<String> ids) => {
      for (final (i, id) in ids.indexed)
        id: (bytes: Uint8List.fromList([i + 1]), mimeType: 'image/png'),
    };
    String b64(int index) => base64Encode([index + 1]);
    Message user(List<ContentBlock> content) =>
        testMessage(MessageRole.user, content);
    Message assistant(List<ContentBlock> content) =>
        testMessage(MessageRole.assistant, content);
    Map<String, dynamic> body(
      List<Message> history, {
      ImageSettings options = const ImageSettings(),
      ImageBytesMap imageBytes = const {},
    }) => codec.imagesRequestBody(
      model: 'qwen-mlx',
      profile: ImageRequestProfile(
        image: options,
        api: ImageApi.imagesEndpoint,
      ),
      history: history,
      imageBytes: imageBytes,
    );
    Matcher refuses(String because) => throwsA(
      isA<UnsendableImageRequest>().having(
        (e) => e.message,
        'message',
        contains(because),
      ),
    );
    // A fox, then a cat, were drawn before the last message.
    List<Message> afterTwoPictures(String prompt) => [
      user([text('a fox')]),
      assistant([image('first')]),
      user([text('a cat')]),
      assistant([image('second')]),
      user([text(prompt)]),
    ];

    test('text to image: the last user text, nothing else', () {
      expect(
        body([
          user([text('a fox')]),
          assistant([text('here')]),
          user([text(' a red fox in snow ')]),
        ]),
        {'model': 'qwen-mlx', 'prompt': 'a red fox in snow', 'stream': true},
      );
    });

    test('what the profile holds goes out under the API names', () {
      expect(
        body(
          [
            user([text('x')]),
          ],
          options: const ImageSettings(
            mode: ImageMode.auto,
            aspectRatio: '16:9',
            steps: 8,
            seed: 7,
            guidance: 4.0,
            negativePrompt: 'blurry',
            transparent: true,
          ),
        ),
        {
          'model': 'qwen-mlx',
          'prompt': 'x',
          'size': '1360x768',
          'steps': 8,
          'seed': 7,
          'guidance_scale': 4.0,
          'negative_prompt': 'blurry',
          'transparent': true,
          'stream': true,
        },
      );
    });

    test('size: about the base size squared in the ratio, sides of 16', () {
      String? size(ImageSettings s) =>
          body([
                user([text('x')]),
              ], options: s)['size']
              as String?;
      expect(size(const ImageSettings()), isNull);
      expect(size(const ImageSettings(baseSize: 1536)), '1536x1536');
      expect(size(const ImageSettings(aspectRatio: '9:16')), '768x1360');
      expect(
        size(const ImageSettings(baseSize: 768, aspectRatio: '3:2')),
        '944x624',
      );
      expect(size(const ImageSettings(aspectRatio: 'wide')), isNull);
    });

    test("the last turn's images are edited: the first, then references", () {
      final b = body(
        [
          user([text('put the hat from 2 on 1'), image('a'), image('b')]),
        ],
        imageBytes: bytesOf(['a', 'b']),
        options: const ImageSettings(baseSize: 1536),
      );
      expect(b['image'], b64(0));
      expect(b['ref_images'], [b64(1)]);
      expect(b['mode'], 'edit');
      // An edit that sets no ratio keeps its reference's shape.
      expect(b.containsKey('size'), isFalse);
    });

    test('Auto with nothing attached draws a new picture', () {
      // The conversation holds pictures; the prompt is not about them.
      final b = body(
        afterTwoPictures('a city skyline at night'),
        imageBytes: bytesOf(['first', 'second']),
      );
      expect(b, {
        'model': 'qwen-mlx',
        'prompt': 'a city skyline at night',
        'stream': true,
      });
    });

    test('Edit: "now make it blue" edits the latest picture', () {
      final b = body(
        afterTwoPictures('now make it blue'),
        imageBytes: bytesOf(['first', 'second']),
        options: const ImageSettings(mode: ImageMode.edit),
      );
      expect(b['prompt'], 'now make it blue');
      expect(b['image'], b64(1));
      expect(b['mode'], 'edit');
      expect(b.containsKey('ref_images'), isFalse);
    });

    test('Generate sends no image; an image not loaded is left out', () {
      final history = [
        user([text('again'), image('a'), image('b')]),
      ];
      final generate = body(
        history,
        imageBytes: bytesOf(['a', 'b']),
        options: const ImageSettings(mode: ImageMode.generate),
      );
      expect(generate.containsKey('image'), isFalse);
      expect(generate.containsKey('mode'), isFalse);

      final partial = body(
        history,
        imageBytes: {
          'b': bytesOf(['b'])['b']!,
        },
      );
      expect(partial['image'], b64(0));
      expect(partial.containsKey('ref_images'), isFalse);
    });

    test('Edit with nothing to edit is refused, not drawn from scratch', () {
      const edit = ImageSettings(mode: ImageMode.edit);
      expect(
        () => body([
          user([text('remove the lamp post')]),
        ], options: edit),
        refuses('Edit needs an image'),
      );
      // An image whose bytes are gone is nothing to edit either.
      expect(
        () => body(afterTwoPictures('make it blue'), options: edit),
        refuses('Edit needs an image'),
      );
    });

    test('no text, no request', () {
      expect(
        () => body([
          user([image('a')]),
        ], imageBytes: bytesOf(['a'])),
        refuses('needs a prompt'),
      );
      expect(() => body(const []), refuses('needs a prompt'));
    });
  });

  group('imagesResponseData', () {
    test('the pictures of a `data` array, base64 or address', () {
      expect(
        OpenAiCodec.imagesResponseData(const {
          'created': 0,
          'data': [
            {'b64_json': 'AQID'},
            {'url': 'https://cdn.example/x.png'},
            {'revised_prompt': 'neither'},
            {'b64_json': ''},
            'not an entry',
          ],
        }),
        [
          (base64: 'AQID', url: null),
          (base64: null, url: 'https://cdn.example/x.png'),
        ],
      );
      expect(OpenAiCodec.imagesResponseData(const {'data': 'x'}), isEmpty);
      expect(OpenAiCodec.imagesResponseData(const {}), isEmpty);
    });

    // OpenAI's own streaming: the picture is on the closing event.
    test('the picture of a closing event; a partial one is a preview', () {
      expect(
        OpenAiCodec.imagesResponseData(const {
          'type': 'image_generation.completed',
          'b64_json': 'AQID',
          'usage': {'total_tokens': 100},
        }),
        [(base64: 'AQID', url: null)],
      );
      expect(
        OpenAiCodec.imagesResponseData(const {
          'type': 'image_generation.partial_image',
          'b64_json': 'AQID',
          'partial_image_index': 0,
        }),
        isEmpty,
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
