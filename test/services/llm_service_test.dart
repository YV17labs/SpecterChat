import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:specterchat/models/app_settings.dart';
import 'package:specterchat/services/llm_service.dart';

void main() {
  late Dio dio;
  late DioAdapter dioAdapter;
  late LlmService service;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://test.local/v1'));
    dioAdapter = DioAdapter(dio: dio);
    service = LlmService(
      dio: dio,
      apiSettings: const ApiSettings(
        baseUrl: 'http://test.local/v1',
        selectedModel: 'test-model',
      ),
      generationSettings: const GenerationSettings(),
    );
  });

  group('LlmService.fetchModels', () {
    test('returns sorted model list', () async {
      dioAdapter.onGet(
        '/models',
        (server) => server.reply(200, {
          'data': [
            {'id': 'model-b'},
            {'id': 'model-a'},
            {'id': 'model-c'},
          ],
        }),
      );

      final models = await service.fetchModels();
      expect(models, ['model-a', 'model-b', 'model-c']);
    });

    test('throws LlmException on network error', () async {
      dioAdapter.onGet(
        '/models',
        (server) => server.throws(
          500,
          DioException(
            requestOptions: RequestOptions(path: '/models'),
            message: 'Server error',
          ),
        ),
      );

      expect(
        () => service.fetchModels(),
        throwsA(isA<LlmException>()),
      );
    });
  });

  group('LlmService.fromSettings', () {
    test('creates a working service', () {
      final svc = LlmService.fromSettings(
        apiSettings: const ApiSettings(
          baseUrl: 'http://localhost:1234/v1',
          apiKey: 'sk-test',
          selectedModel: 'gpt-4',
        ),
        generationSettings: const GenerationSettings(),
      );
      expect(svc, isA<LlmService>());
    });
  });

  group('StreamEvent types', () {
    test('ContentDelta holds text', () {
      final e = ContentDelta('hello');
      expect(e.text, 'hello');
    });

    test('ThinkingDelta holds text', () {
      final e = ThinkingDelta('hmm');
      expect(e.text, 'hmm');
    });

    test('ToolCallDelta holds all fields', () {
      final e = ToolCallDelta(
        index: 0,
        id: 'tc-1',
        name: 'search',
        argumentsDelta: '{"q":',
      );
      expect(e.index, 0);
      expect(e.id, 'tc-1');
      expect(e.name, 'search');
      expect(e.argumentsDelta, '{"q":');
    });

    test('StreamError holds message', () {
      final e = StreamError('something failed');
      expect(e.message, 'something failed');
    });
  });

  group('LlmException', () {
    test('toString returns message', () {
      final e = LlmException('test error');
      expect(e.toString(), 'test error');
    });
  });
}
