import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/models/app_settings.dart';
import 'package:specterchat/services/llm_service.dart';

/// Creates a fake streaming response from SSE lines.
ResponseBody _fakeStreamResponse(List<String> sseLines) {
  final data = sseLines.join('\n');
  final stream = Stream.value(utf8.encode(data));
  return ResponseBody(stream, 200);
}

/// A Dio interceptor that returns a fake streaming response.
class _FakeStreamInterceptor extends Interceptor {
  final List<String> sseLines;

  _FakeStreamInterceptor(this.sseLines);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.path == '/chat/completions') {
      handler.resolve(Response(
        requestOptions: options,
        data: _fakeStreamResponse(sseLines),
        statusCode: 200,
      ));
    } else {
      handler.next(options);
    }
  }
}

void main() {
  late Dio dio;
  late LlmService service;

  LlmService createService(List<String> sseLines) {
    dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));
    dio.interceptors.add(_FakeStreamInterceptor(sseLines));
    return LlmService(
      dio: dio,
      apiSettings: const ApiSettings(
        baseUrl: 'http://test.local/v1',
        selectedModel: 'test-model',
      ),
      generationSettings: const GenerationSettings(),
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'hi'}
            ],
          )
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
          .toList();

      expect(events[0], isA<ThinkingDelta>());
      expect((events[0] as ThinkingDelta).text, 'hmm');
    });

    test('splits inline <think>...</think> from content (llama.cpp default)',
        () async {
      service = createService([
        'data: {"choices":[{"delta":{"content":"<think>let me reason"}}]}',
        'data: {"choices":[{"delta":{"content":" carefully</think>\\n\\nThe answer"}}]}',
        'data: {"choices":[{"delta":{"content":" is 42"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'q'}
            ],
          )
          .toList();

      final thinking = events.whereType<ThinkingDelta>().map((e) => e.text).join();
      final content = events.whereType<ContentDelta>().map((e) => e.text).join();
      expect(thinking, 'let me reason carefully');
      expect(content, 'The answer is 42');
    });

    test('splits <think> tag that spans two deltas', () async {
      service = createService([
        'data: {"choices":[{"delta":{"content":"prefix <th"}}]}',
        'data: {"choices":[{"delta":{"content":"ink>secret</th"}}]}',
        'data: {"choices":[{"delta":{"content":"ink>visible"}}]}',
        'data: [DONE]',
        '',
      ]);

      final events = await service
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'q'}
            ],
          )
          .toList();

      final thinking = events.whereType<ThinkingDelta>().map((e) => e.text).join();
      final content = events.whereType<ContentDelta>().map((e) => e.text).join();
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'q'}
            ],
          )
          .toList();

      final thinking = events.whereType<ThinkingDelta>().map((e) => e.text).join();
      final content = events.whereType<ContentDelta>().map((e) => e.text).join();
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
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
            messages: [
              {'role': 'user', 'content': 'search dart'}
            ],
            tools: [
              {
                'type': 'function',
                'function': {
                  'name': 'search',
                  'parameters': {'type': 'object'},
                },
              }
            ],
          )
          .toList();

      final tcEvents =
          events.whereType<ToolCallDelta>().toList();
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
          .toList();

      // Should skip the malformed line and still get content
      expect(events.whereType<ContentDelta>().length, 1);
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
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
          .toList();

      expect(events.whereType<ContentDelta>().length, 1);
    });

    test('includes topK and repeatPenalty when non-default', () async {
      dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));

      Map<String, dynamic>? capturedBody;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          capturedBody = options.data as Map<String, dynamic>?;
          handler.resolve(Response(
            requestOptions: options,
            data: _fakeStreamResponse(['data: [DONE]', '']),
            statusCode: 200,
          ));
        },
      ));

      final svc = LlmService(
        dio: dio,
        apiSettings: const ApiSettings(
          baseUrl: 'http://test.local/v1',
          selectedModel: 'test',
        ),
        generationSettings: const GenerationSettings(
          topK: 40,
          repeatPenalty: 1.2,
        ),
      );

      await svc
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
          .toList();

      expect(capturedBody?['top_k'], 40);
      expect(capturedBody?['repeat_penalty'], 1.2);
    });

    test('does not include topK when 0 or repeatPenalty when 1.0',
        () async {
      dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));

      Map<String, dynamic>? capturedBody;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          capturedBody = options.data as Map<String, dynamic>?;
          handler.resolve(Response(
            requestOptions: options,
            data: _fakeStreamResponse(['data: [DONE]', '']),
            statusCode: 200,
          ));
        },
      ));

      final svc = LlmService(
        dio: dio,
        apiSettings: const ApiSettings(
          baseUrl: 'http://test.local/v1',
          selectedModel: 'test',
        ),
        generationSettings: const GenerationSettings(),
      );

      await svc
          .streamChatCompletion(
            messages: [
              {'role': 'user', 'content': 'test'}
            ],
          )
          .toList();

      expect(capturedBody?.containsKey('top_k'), false);
      expect(capturedBody?.containsKey('repeat_penalty'), false);
    });
  });

}
