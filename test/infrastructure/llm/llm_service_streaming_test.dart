import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/domain/models/request_profile.dart';
import 'package:specterchat/domain/services/cancellation_token.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/infrastructure/llm/llm_service.dart';

final _history = [
  Message(
    id: 'm',
    conversationId: 'c',
    role: MessageRole.user,
    content: [const ContentBlock.text(text: 'hi')],
    createdAt: DateTime(2024),
  ),
];

/// Creates a fake streaming response from SSE lines.
ResponseBody _fakeStreamResponse(List<String> sseLines) {
  final data = sseLines.join('\n');
  final stream = Stream.value(utf8.encode(data));
  return ResponseBody(stream, 200);
}

/// A Dio interceptor that returns a fake streaming response.
class _FakeStreamInterceptor extends Interceptor {
  final List<String> sseLines;

  /// Every `/chat/completions` or `/images/generations` body seen, and
  /// where it went, for request-shape assertions.
  final List<Map<String, dynamic>> bodies = [];
  final List<String> paths = [];

  _FakeStreamInterceptor(this.sseLines);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.path == '/chat/completions' ||
        options.path == '/images/generations') {
      paths.add(options.path);
      bodies.add(Map<String, dynamic>.from(options.data as Map));
      handler.resolve(
        Response(
          requestOptions: options,
          data: _fakeStreamResponse(sseLines),
          statusCode: 200,
        ),
      );
    } else {
      handler.next(options);
    }
  }
}

void main() {
  late Dio dio;
  late LlmService service;
  late _FakeStreamInterceptor interceptor;

  LlmService createService(
    List<String> sseLines, {
    String selectedModel = 'test-model',
  }) {
    dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));
    interceptor = _FakeStreamInterceptor(sseLines);
    dio.interceptors.add(interceptor);
    return LlmService(
      dio: dio,
      apiSettings: ApiSettings(
        baseUrl: 'http://test.local/v1',
        selectedModel: selectedModel,
      ),
    );
  }

  group('LlmService.streamChatCompletion', () {
    test('yields ContentDelta for content chunks', () async {
      service = createService([
        'data: {"choices":[{"delta":{"content":"Hello"}}]}',
        'data: {"choices":[{"delta":{"content":" world"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events, hasLength(3));
      expect(events[0], isA<ContentDelta>());
      expect((events[0] as ContentDelta).text, 'Hello');
      expect(events[1], isA<ContentDelta>());
      expect((events[1] as ContentDelta).text, ' world');
      expect(events[2], isA<StreamDone>());
    });

    test('yields ThinkingDelta for reasoning content', () async {
      service = createService([
        'data: {"choices":[{"delta":{"reasoning_content":"Let me think"}}]}',
        'data: {"choices":[{"delta":{"content":"Answer"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events[0], isA<ThinkingDelta>());
      expect((events[0] as ThinkingDelta).text, 'Let me think');
      expect(events[1], isA<ContentDelta>());
    });

    test('yields ThinkingDelta for thinking field', () async {
      service = createService([
        'data: {"choices":[{"delta":{"thinking":"hmm"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events[0], isA<ThinkingDelta>());
      expect((events[0] as ThinkingDelta).text, 'hmm');
    });

    test(
      'splits inline <think>...</think> from content (llama.cpp default)',
      () async {
        service = createService([
          'data: {"choices":[{"delta":{"content":"<think>let me reason"}}]}',
          'data: {"choices":[{"delta":{"content":" carefully</think>\\n\\nThe answer"}}]}',
          'data: {"choices":[{"delta":{"content":" is 42"}}]}',
          'data: [DONE]',
          '',
        ]);

        final events = await service
            .streamChatCompletion(history: _history, systemPrompt: '')
            .toList();

        final thinking = events
            .whereType<ThinkingDelta>()
            .map((e) => e.text)
            .join();
        final content = events
            .whereType<ContentDelta>()
            .map((e) => e.text)
            .join();
        expect(thinking, 'let me reason carefully');
        expect(content, 'The answer is 42');
      },
    );

    test('splits <think> tag that spans two deltas', () async {
      service = createService([
        'data: {"choices":[{"delta":{"content":"prefix <th"}}]}',
        'data: {"choices":[{"delta":{"content":"ink>secret</th"}}]}',
        'data: {"choices":[{"delta":{"content":"ink>visible"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      final thinking = events
          .whereType<ThinkingDelta>()
          .map((e) => e.text)
          .join();
      final content = events
          .whereType<ContentDelta>()
          .map((e) => e.text)
          .join();
      expect(thinking, 'secret');
      expect(content, 'prefix visible');
    });

    test('splits explicit <think>...</think> from content', () async {
      // For DeepSeek-R1, llama.cpp default mode, and any server that emits
      // the opening tag as part of the generated stream.
      service = createService([
        'data: {"choices":[{"delta":{"content":"<think>plan</think>do it"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      final thinking = events
          .whereType<ThinkingDelta>()
          .map((e) => e.text)
          .join();
      final content = events
          .whereType<ContentDelta>()
          .map((e) => e.text)
          .join();
      expect(thinking, 'plan');
      expect(content, 'do it');
    });

    test('yields ThinkingDelta for mlx_vlm reasoning field', () async {
      service = createService([
        'data: {"choices":[{"delta":{"reasoning":"step by step"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events[0], isA<ThinkingDelta>());
      expect((events[0] as ThinkingDelta).text, 'step by step');
    });

    test('yields ToolCallDelta for tool calls', () async {
      service = createService([
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"tc-1","function":{"name":"search","arguments":"{\\"q\\":"}}]}}]}',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"dart\\"}"}}]}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(
            history: _history,
            systemPrompt: '',
            tools: const [
              McpToolInfo(
                name: 'search',
                description: 'Search',
                inputSchema: {'type': 'object'},
              ),
            ],
          )
          .toList();

      final tcEvents = events.whereType<ToolCallDelta>().toList();
      expect(tcEvents, hasLength(2));
      expect(tcEvents[0].id, 'tc-1');
      expect(tcEvents[0].name, 'search');
      expect(tcEvents[0].argumentsDelta, '{"q":');
      expect(tcEvents[1].argumentsDelta, '"dart"}');
    });

    test('yields StreamDone when no DONE marker (stream ends)', () async {
      service = createService([
        'data: {"choices":[{"delta":{"content":"hi"}}]}',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events.last, isA<StreamDone>());
    });

    test('skips empty lines and non-data lines', () async {
      service = createService([
        '',
        ': comment',
        'data: {"choices":[{"delta":{"content":"ok"}}]}',
        '',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events.whereType<ContentDelta>().length, 1);
    });

    test('skips malformed JSON gracefully', () async {
      service = createService([
        'data: {invalid json}',
        'data: {"choices":[{"delta":{"content":"ok"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      // Should skip the malformed line and still get content
      expect(events.whereType<ContentDelta>().length, 1);
    });

    // The session waits for a terminal event: a parser that throws must
    // not escape as a stream error, or the turn never ends.
    test('a chunk of an unexpected shape ends the turn as an error', () async {
      service = createService([
        'data: {"choices":[{"delta":{"content":"Hello"}}]}',
        'data: {"choices":[{"delta":{"content":["not","a","string"]}}]}',
        'data: {"choices":[{"delta":{"content":"never read"}}]}',
        'data: [DONE]',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events.whereType<ContentDelta>().single.text, 'Hello');
      expect(events.last, isA<StreamError>());
      expect(
        (events.last as StreamError).message,
        startsWith('Unexpected error'),
      );
    });

    test('`data:` is read with or without the space after it', () async {
      service = createService([
        'data:{"choices":[{"delta":{"content":"Hello"}}]}',
        'data:   {"choices":[{"delta":{"content":" world"}}]}',
        'data:[DONE]',
        'data: {"choices":[{"delta":{"content":"after the end"}}]}',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events.whereType<ContentDelta>().map((e) => e.text), [
        'Hello',
        ' world',
      ]);
      expect(events.last, isA<StreamDone>());
    });

    test('skips chunks with null/empty choices', () async {
      service = createService([
        'data: {"choices":null}',
        'data: {"choices":[]}',
        'data: {"choices":[{"delta":{"content":"ok"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();

      expect(events.whereType<ContentDelta>().length, 1);
    });

    test('includes topK and repeatPenalty when non-default', () async {
      await createService(['data: [DONE]', ''])
          .streamChatCompletion(
            history: _history,
            systemPrompt: '',
            profile: const TextRequestProfile(
              generation: GenerationSettings(topK: 40, repeatPenalty: 1.2),
            ),
          )
          .toList();
      final body = interceptor.bodies.single;
      expect(body['top_k'], 40);
      expect(body['repeat_penalty'], 1.2);
    });

    test('does not include topK when 0 or repeatPenalty when 1.0', () async {
      await createService([
        'data: [DONE]',
        '',
      ]).streamChatCompletion(history: _history, systemPrompt: '').toList();
      final body = interceptor.bodies.single;
      expect(body.containsKey('top_k'), false);
      expect(body.containsKey('repeat_penalty'), false);
    });
  });

  group('LlmService cancellation', () {
    test(
      'a token cancelled before the request yields StreamCancelled only',
      () async {
        service = createService(['data: [DONE]', '']);
        final token = CancellationToken()..cancel();
        final events = await service
            .streamChatCompletion(
              history: _history,
              systemPrompt: '',
              cancellationToken: token,
            )
            .toList();
        expect(events, [isA<StreamCancelled>()]);
      },
    );

    test(
      'cancelling mid-stream ends with StreamCancelled, not StreamDone',
      () async {
        final token = CancellationToken();
        dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final controller = StreamController<Uint8List>();
              controller.add(
                utf8.encode('data: {"choices":[{"delta":{"content":"a"}}]}\n'),
              );
              // Cancel once the first chunk is out, then let the body end.
              Future<void>.delayed(const Duration(milliseconds: 10), () async {
                token.cancel();
                controller.add(
                  utf8.encode(
                    'data: {"choices":[{"delta":{"content":"b"}}]}\n',
                  ),
                );
                await controller.close();
              });
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: ResponseBody(controller.stream, 200),
                  statusCode: 200,
                ),
              );
            },
          ),
        );
        final svc = LlmService(
          dio: dio,
          apiSettings: const ApiSettings(selectedModel: 'test'),
        );
        final events = await svc
            .streamChatCompletion(
              history: _history,
              systemPrompt: '',
              cancellationToken: token,
            )
            .toList();
        expect(events.last, isA<StreamCancelled>());
        expect(events.whereType<StreamDone>(), isEmpty);
      },
    );
  });

  group('LlmService image/progress extensions', () {
    test('yields ProgressDelta for the progress extension', () async {
      service = createService([
        'data: {"choices":[{"delta":{"progress":{"stage":"generating","step":12,"total":40,"percent":30,"message":"Génération 12/40"}}}]}',
        'data: [DONE]',
        '',
      ]);
      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();
      final p = events.whereType<ProgressDelta>().single.progress;
      expect(p.stage, 'generating');
      expect(p.step, 12);
      expect(p.total, 40);
      expect(p.percent, 30);
      expect(p.message, 'Génération 12/40');
    });

    test('a progress field of another type is left out', () async {
      service = createService([
        'data: {"choices":[{"delta":{"progress":{"stage":"load","step":"3","total":0,"message":7}}}]}',
        'data: {"choices":[{"delta":{"progress":{"stage":7}}}]}',
        'data: [DONE]',
      ]);
      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();
      final p = events.whereType<ProgressDelta>().single.progress;
      expect((p.stage, p.step, p.total, p.message), ('load', null, null, null));
      expect(events.last, isA<StreamDone>());
    });

    test('yields ImageDelta for data-URL images', () async {
      service = createService([
        'data: {"choices":[{"delta":{"images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"},"generation":{"seed":7}}]}}]}',
        'data: [DONE]',
        '',
      ]);
      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();
      final img = events.whereType<ImageDelta>().single;
      expect(img.mimeType, 'image/png');
      expect(img.bytes, [1, 2, 3]);
      expect(events.last, isA<StreamDone>());
    });

    test('a multi-megabyte single line survives chunked delivery', () async {
      // 6 MB of base64 on one `data:` line, delivered in 64 KB packets.
      final payload = base64Encode(Uint8List(6 * 1024 * 1024));
      final line =
          'data: {"choices":[{"delta":{"images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,$payload"}}]}}]}\n'
          'data: [DONE]\n';
      final bytes = utf8.encode(line);
      const packet = 64 * 1024;
      Stream<Uint8List> packets() async* {
        for (var i = 0; i < bytes.length; i += packet) {
          yield Uint8List.sublistView(
            bytes,
            i,
            (i + packet).clamp(0, bytes.length),
          );
        }
      }

      dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              data: ResponseBody(packets(), 200),
              statusCode: 200,
            ),
          ),
        ),
      );
      service = LlmService(
        dio: dio,
        apiSettings: const ApiSettings(
          baseUrl: 'http://test.local/v1',
          selectedModel: 'test-model',
        ),
      );

      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();
      final img = events.whereType<ImageDelta>().single;
      expect(img.bytes.length, 6 * 1024 * 1024);
      expect(events.last, isA<StreamDone>());
    });

    test(
      'a mid-stream error envelope ends the turn with StreamError',
      () async {
        service = createService([
          'data: {"choices":[{"delta":{"content":"Génération"}}]}',
          'data: {"error":{"message":"out of memory","type":"server_error"}}',
          'data: [DONE]',
          '',
        ]);
        final events = await service
            .streamChatCompletion(history: _history, systemPrompt: '')
            .toList();
        expect(events.whereType<ContentDelta>().single.text, 'Génération');
        final err = events.whereType<StreamError>().single;
        expect(err.message, contains('out of memory'));
      },
    );

    test('a UTF-8 character split across packets decodes intact', () async {
      final line = utf8.encode(
        'data: {"choices":[{"delta":{"content":"café"}}]}\ndata: [DONE]\n',
      );
      // Split inside the 2-byte "é".
      final cut = line.indexOf(0xC3) + 1;
      dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              data: ResponseBody(
                Stream.fromIterable([
                  Uint8List.fromList(line.sublist(0, cut)),
                  Uint8List.fromList(line.sublist(cut)),
                ]),
                200,
              ),
              statusCode: 200,
            ),
          ),
        ),
      );
      service = LlmService(
        dio: dio,
        apiSettings: const ApiSettings(
          baseUrl: 'http://test.local/v1',
          selectedModel: 'test-model',
        ),
      );
      final events = await service
          .streamChatCompletion(history: _history, systemPrompt: '')
          .toList();
      expect(events.whereType<ContentDelta>().single.text, 'café');
    });
  });

  group('request body per profile', () {
    const tool = McpToolInfo(
      name: 't',
      description: 'd',
      inputSchema: {'type': 'object'},
    );
    final done = ['data: [DONE]', ''];

    test('text profile: sampling fields, system prompt and tools', () async {
      await createService(done, selectedModel: 'llama')
          .streamChatCompletion(
            history: _history,
            systemPrompt: 'be terse',
            profile: const TextRequestProfile(
              generation: GenerationSettings(temperature: 0.3),
            ),
            tools: const [tool],
          )
          .toList();
      final body = interceptor.bodies.single;
      expect(body['temperature'], 0.3);
      // The token cap goes out as `max_tokens`: Ollama reads no other
      // name and drops the limit entirely without it.
      expect(body['max_tokens'], 4096);
      expect(body.containsKey('generation'), isFalse);
      expect((body['messages'] as List).first, {
        'role': 'system',
        'content': 'be terse',
      });
      expect(body['tools'], isNotEmpty);
    });

    test(
      'image profile: generation object, no sampling/system/tools',
      () async {
        await createService(done, selectedModel: 'qwen-image-2.1')
            .streamChatCompletion(
              history: _history,
              systemPrompt: 'be terse',
              profile: const ImageRequestProfile(
                image: ImageSettings(steps: 5, aspectRatio: '16:9'),
              ),
              tools: const [tool],
            )
            .toList();
        final body = interceptor.bodies.single;
        expect(body['model'], 'qwen-image-2.1');
        expect(body['stream'], isTrue);
        expect(body['generation'], {'aspect_ratio': '16:9', 'steps': 5});
        for (final key in [
          'temperature',
          'top_p',
          'max_tokens',
          'frequency_penalty',
          'presence_penalty',
          'tools',
          'tool_choice',
        ]) {
          expect(body.containsKey(key), isFalse, reason: key);
        }
        final roles = (body['messages'] as List).map((m) => (m as Map)['role']);
        expect(roles, isNot(contains('system')));
      },
    );

    test(
      'image profile with default settings sends no generation key',
      () async {
        await createService(done, selectedModel: 'qwen-image-2.1')
            .streamChatCompletion(
              history: _history,
              systemPrompt: '',
              profile: const ImageRequestProfile(),
            )
            .toList();
        expect(interceptor.bodies.single.containsKey('generation'), isFalse);
      },
    );

    test('a call without a profile is a plain text request', () async {
      await createService(
        done,
        selectedModel: 'llama',
      ).streamChatCompletion(history: _history, systemPrompt: '').toList();
      final body = interceptor.bodies.single;
      expect(body['temperature'], const GenerationSettings().temperature);
      expect(body.containsKey('generation'), isFalse);
    });
  });

  group('Images API model', () {
    const profile = ImageRequestProfile(api: ImageApi.imagesEndpoint);
    // A PNG signature is all the sniffer reads.
    final png = base64Encode([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    Message user(List<ContentBlock> content) => Message(
      id: 'm',
      conversationId: 'c',
      role: MessageRole.user,
      content: content,
      createdAt: DateTime(2024),
    );
    Future<List<StreamEvent>> run(
      List<String> lines, {
      List<Message>? history,
      ImageBytesMap imageBytes = const {},
      ImageRequestProfile profile = profile,
    }) => createService(lines, selectedModel: 'qwen-mlx')
        .streamChatCompletion(
          history: history ?? _history,
          systemPrompt: 'never sent',
          profile: profile,
          imageBytes: imageBytes,
        )
        .toList();

    test('progress, then the picture: asked at images/generations', () async {
      final events = await run(
        [
          'data: {"type":"progress","stage":"load","step":0,"total":0}',
          '',
          'data: {"type":"progress","stage":"denoise","step":3,"total":8}',
          '',
          'data: {"type":"complete","created":0,"data":[{"b64_json":"$png"}]}',
          '',
        ],
        // The seed the session drew for the turn travels like any other.
        profile: const ImageRequestProfile(
          image: ImageSettings(seed: 1234),
          api: ImageApi.imagesEndpoint,
        ),
      );

      expect(interceptor.paths, ['/images/generations']);
      expect(interceptor.bodies.single, {
        'model': 'qwen-mlx',
        'prompt': 'hi',
        'seed': 1234,
        'stream': true,
      });
      expect(
        events.whereType<ProgressDelta>().map(
          (e) => (e.progress.stage, e.progress.step, e.progress.total),
        ),
        [('load', 0, null), ('denoise', 3, 8)],
      );
      final image = events.whereType<ImageDelta>().single;
      expect(image.mimeType, 'image/png');
      expect(image.bytes, base64Decode(png));
      expect(image.textToImage, isTrue);
      expect(events.whereType<ServerReport>().single.fields, {'created': 0});
      expect(events.last, isA<StreamDone>());
    });

    test('an edit is not text to image', () async {
      final events = await run(
        ['data: {"type":"complete","data":[{"b64_json":"$png"}]}'],
        history: [
          user(const [
            ContentBlock.text(text: 'make it blue'),
            ContentBlock.image(
              attachmentId: 'a',
              mimeType: 'image/png',
              byteSize: 1,
            ),
          ]),
        ],
        imageBytes: {
          'a': (bytes: Uint8List.fromList([1]), mimeType: 'image/png'),
        },
      );
      expect(interceptor.bodies.single['mode'], 'edit');
      expect(events.whereType<ImageDelta>().single.textToImage, isFalse);
    });

    test('an error event ends the turn with its message', () async {
      final events = await run([
        'data: {"type":"error","message":"transparent: not on this model"}',
      ]);
      expect(
        events.whereType<StreamError>().single.message,
        'API error: transparent: not on this model',
      );
    });

    test('a server that does not stream answers with the body', () async {
      final events = await run(['{"created":0,"data":[{"b64_json":"$png"}]}']);
      expect(events.whereType<ImageDelta>(), hasLength(1));
      expect(events.last, isA<StreamDone>());
    });

    // OpenAI's own streaming: previews, then the picture on the closing
    // event — megabytes of base64 that must not be recorded as a report.
    test('a picture on the closing event; previews are skipped', () async {
      final events = await run([
        'data: {"type":"image_generation.partial_image","b64_json":"$png","partial_image_index":0}',
        '',
        'data: {"type":"image_generation.completed","b64_json":"$png","usage":{"total_tokens":10}}',
      ]);
      expect(events.whereType<ImageDelta>(), hasLength(1));
      final reported = {
        for (final report in events.whereType<ServerReport>()) ...report.fields,
      };
      expect(reported, {
        'partial_image_index': 0,
        'usage': {'total_tokens': 10},
      });
      expect(events.last, isA<StreamDone>());
    });

    test('an answer without a picture is an error, not an empty reply', () {
      final withoutPicture = <String, List<String>>{
        'an empty data array': ['data: {"type":"complete","data":[]}'],
        'a format the app does not read': [
          'data: {"type":"complete","data":[{"b64_json":"${base64Encode([1, 2, 3])}"}]}',
        ],
        'a page that is not the API': ['<html><body>It works!</body></html>'],
        'nothing but progress': ['data: {"type":"progress","stage":"load"}'],
      };
      return Future.wait([
        for (final MapEntry(key: what, value: lines) in withoutPicture.entries)
          run(lines).then((events) {
            expect(events.whereType<StreamDone>(), isEmpty, reason: what);
            expect(
              (events.last as StreamError).message,
              'The server answered without a picture.',
              reason: what,
            );
          }),
      ]);
    });

    test('a progress field of another type does not fail the turn', () async {
      final events = await run([
        'data: {"type":"progress","stage":"denoise","step":"3","total":"8"}',
        'data: {"type":"complete","data":[{"b64_json":"$png"}]}',
      ]);
      final p = events.whereType<ProgressDelta>().single.progress;
      expect((p.stage, p.step, p.total), ('denoise', null, null));
      expect(events.whereType<ImageDelta>(), hasLength(1));
      expect(events.last, isA<StreamDone>());
    });

    test('no text in the last message: an error, nothing sent', () async {
      final events = await run(const [], history: [user(const [])]);
      expect(interceptor.bodies, isEmpty);
      expect(events.single, isA<StreamError>());
    });

    test('Edit with nothing to edit: an error, nothing sent', () async {
      final events = await run(
        const [],
        profile: const ImageRequestProfile(
          image: ImageSettings(mode: ImageMode.edit),
          api: ImageApi.imagesEndpoint,
        ),
      );
      expect(interceptor.bodies, isEmpty);
      expect(
        (events.single as StreamError).message,
        contains('Edit needs an image'),
      );
    });
  });

  group('a picture given as a URL', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
    late List<({Uri uri, Object? authorization})> fetched;

    Future<List<StreamEvent>> run(String url) {
      fetched = [];
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://api.local:8080/v1',
          headers: {'Authorization': 'Bearer secret'},
        ),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'GET') {
              fetched.add((
                uri: options.uri,
                authorization: options.headers['Authorization'],
              ));
              return handler.resolve(
                Response(
                  requestOptions: options,
                  data: png,
                  statusCode: 200,
                  headers: Headers.fromMap({
                    'content-type': ['image/png'],
                  }),
                ),
              );
            }
            handler.resolve(
              Response(
                requestOptions: options,
                data: _fakeStreamResponse([
                  'data: {"type":"complete","data":[{"url":"$url"}]}',
                ]),
                statusCode: 200,
              ),
            );
          },
        ),
      );
      return LlmService(
            dio: dio,
            apiSettings: const ApiSettings(
              baseUrl: 'http://api.local:8080/v1',
              selectedModel: 'm',
            ),
          )
          .streamChatCompletion(
            history: _history,
            systemPrompt: '',
            profile: const ImageRequestProfile(api: ImageApi.imagesEndpoint),
          )
          .toList();
    }

    test('on the API server: fetched with the key', () async {
      final events = await run('/v1/files/abc.png');
      expect(
        fetched.single.uri.toString(),
        'http://api.local:8080/v1/files/abc.png',
      );
      expect(fetched.single.authorization, 'Bearer secret');
      expect(events.whereType<ImageDelta>().single.bytes, png);

      await run('http://api.local:8080/files/abc.png');
      expect(fetched.single.authorization, 'Bearer secret');
    });

    test('on another host: fetched without the key', () async {
      for (final elsewhere in [
        'https://cdn.example.com/abc.png',
        // Same host, another port or scheme: another origin.
        'http://api.local:9090/abc.png',
        'https://api.local:8080/abc.png',
      ]) {
        final events = await run(elsewhere);
        expect(fetched.single.uri.toString(), elsewhere);
        expect(fetched.single.authorization, isNull, reason: elsewhere);
        expect(events.whereType<ImageDelta>(), hasLength(1));
      }
    });

    test('an address that is not http(s) is not fetched', () async {
      final events = await run('file:///etc/passwd');
      expect(fetched, isEmpty);
      expect(events.last, isA<StreamError>());
    });
  });

  group('request log', () {
    Future<String> logged(Future<void> Function() request) async {
      final records = <LogRecord>[];
      final previous = Logger.root.level;
      Logger.root.level = Level.INFO;
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(() {
        Logger.root.level = previous;
        return sub.cancel();
      });
      await request();
      return records
          .map((r) => r.message)
          .singleWhere((m) => m.startsWith('POST '));
    }

    Message user(List<ContentBlock> content) => Message(
      id: 'm',
      conversationId: 'c',
      role: MessageRole.user,
      content: content,
      createdAt: DateTime(2024),
    );

    test('pictures are summarised, bare base64 included', () async {
      final bytes = Uint8List.fromList(List.filled(600, 0xAB));
      final log = await logged(
        () => createService(const ['data: {"type":"complete","data":[]}'])
            .streamChatCompletion(
              history: [
                user(const [
                  ContentBlock.text(text: 'make it blue'),
                  ContentBlock.image(
                    attachmentId: 'a',
                    mimeType: 'image/png',
                    byteSize: 600,
                  ),
                ]),
              ],
              systemPrompt: '',
              profile: const ImageRequestProfile(api: ImageApi.imagesEndpoint),
              imageBytes: {'a': (bytes: bytes, mimeType: 'image/png')},
            )
            .drain<void>(),
      );
      expect(log, contains('"image": "<base64 ~1KB>"'));
      expect(log, isNot(contains(base64Encode(bytes))));
    });

    test('long text without a space is logged as written', () async {
      // Scripts that use no spaces, a long address, compact JSON.
      final texts = [
        '漢字' * 150,
        'https://example.com/${'a/' * 150}',
        '{"k":"${'v' * 300}"}',
      ];
      for (final text in texts) {
        final log = await logged(
          () => createService(const ['data: [DONE]'])
              .streamChatCompletion(
                history: [
                  user([ContentBlock.text(text: text)]),
                ],
                systemPrompt: '',
              )
              .drain<void>(),
        );
        expect(log, contains(jsonEncode(text)));
      }
    });
  });

  group('ServerReport', () {
    test(
      'envelope once, then only what is new: usage, timings, finish_reason',
      () async {
        String chunk(Map<String, Object?> json) => 'data: ${jsonEncode(json)}';
        const envelope = {
          'id': 'chatcmpl-1',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'qwen3',
        };
        service = createService([
          chunk({
            ...envelope,
            'system_fingerprint': 'fp',
            'usage': null,
            'choices': [
              {
                'delta': {'content': 'a'},
                'finish_reason': null,
              },
            ],
          }),
          chunk({
            ...envelope,
            'usage': null,
            'choices': [
              {
                'delta': {'content': 'b'},
                'finish_reason': null,
              },
            ],
          }),
          chunk({
            ...envelope,
            'created': 2,
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'length'},
            ],
          }),
          chunk({
            'id': 'chatcmpl-1',
            'choices': <Object?>[],
            'usage': {
              'prompt_tokens': 9,
              'completion_tokens': 2,
              'prompt_tokens_details': {'cached_tokens': 4},
            },
            'timings': {'predicted_per_second': 31.5},
          }),
          'data: [DONE]',
          '',
        ]);

        final events = await service
            .streamChatCompletion(history: _history, systemPrompt: '')
            .toList();

        final reports = events.whereType<ServerReport>().toList();
        expect(reports.map((r) => r.fields), [
          {
            'id': 'chatcmpl-1',
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'qwen3',
            'system_fingerprint': 'fp',
          },
          {'finish_reason': 'length'},
          {
            'usage': {
              'prompt_tokens': 9,
              'completion_tokens': 2,
              'prompt_tokens_details': {'cached_tokens': 4},
            },
            'timings': {'predicted_per_second': 31.5},
          },
        ]);
        final usage = events.whereType<StreamUsage>().single;
        expect((usage.promptTokens, usage.completionTokens), (9, 2));
        expect(events.whereType<ContentDelta>().map((e) => e.text), ['a', 'b']);
      },
    );
  });
}
