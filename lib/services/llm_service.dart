import 'dart:convert';

import 'package:dio/dio.dart';
import '../models/app_settings.dart';

/// Represents a streamed chunk from the LLM.
sealed class StreamEvent {}

class ContentDelta extends StreamEvent {
  final String text;
  ContentDelta(this.text);
}

class ThinkingDelta extends StreamEvent {
  final String text;
  ThinkingDelta(this.text);
}

class ToolCallDelta extends StreamEvent {
  final int index;
  final String? id;
  final String? name;
  final String argumentsDelta;
  ToolCallDelta({
    required this.index,
    this.id,
    this.name,
    required this.argumentsDelta,
  });
}

class StreamDone extends StreamEvent {}

class StreamError extends StreamEvent {
  final String message;
  StreamError(this.message);
}

/// Service for communicating with OpenAI-compatible LLM APIs.
class LlmService {
  Dio _dio;
  ApiSettings _apiSettings;
  GenerationSettings _generationSettings;

  LlmService({
    required ApiSettings apiSettings,
    required GenerationSettings generationSettings,
  })  : _apiSettings = apiSettings,
        _generationSettings = generationSettings,
        _dio = _createDio(apiSettings);

  static Dio _createDio(ApiSettings settings) {
    return Dio(BaseOptions(
      baseUrl: settings.baseUrl,
      headers: {
        'Content-Type': 'application/json',
        if (settings.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${settings.apiKey}',
      },
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
    ));
  }

  void updateSettings({
    ApiSettings? apiSettings,
    GenerationSettings? generationSettings,
  }) {
    if (apiSettings != null) {
      _apiSettings = apiSettings;
      _dio = _createDio(apiSettings);
    }
    if (generationSettings != null) {
      _generationSettings = generationSettings;
    }
  }

  /// Fetch available models from /v1/models.
  Future<List<String>> fetchModels() async {
    try {
      final response = await _dio.get('/models');
      final data = response.data as Map<String, dynamic>;
      final models = (data['data'] as List)
          .map((m) => m['id'] as String)
          .toList()
        ..sort();
      return models;
    } on DioException catch (e) {
      throw LlmException('Failed to fetch models: ${e.message}');
    }
  }

  /// Send a chat completion request with streaming.
  Stream<StreamEvent> streamChatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async* {
    final body = <String, dynamic>{
      'model': _apiSettings.selectedModel,
      'messages': messages,
      'stream': true,
      'temperature': _generationSettings.temperature,
      'top_p': _generationSettings.topP,
      'max_tokens': _generationSettings.maxTokens,
      'frequency_penalty': _generationSettings.frequencyPenalty,
      'presence_penalty': _generationSettings.presencePenalty,
    };

    if (_generationSettings.topK > 0) {
      body['top_k'] = _generationSettings.topK;
    }
    if (_generationSettings.repeatPenalty != 1.0) {
      body['repeat_penalty'] = _generationSettings.repeatPenalty;
    }
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    try {
      final response = await _dio.post(
        '/chat/completions',
        data: body,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );

      final stream = response.data.stream as Stream<List<int>>;
      String buffer = '';

      await for (final chunk in stream) {
        if (cancelToken?.isCancelled ?? false) break;

        buffer += utf8.decode(chunk);
        final lines = buffer.split('\n');
        // Keep the last potentially incomplete line in the buffer
        buffer = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data: ')) continue;

          final data = trimmed.substring(6);
          if (data == '[DONE]') {
            yield StreamDone();
            return;
          }

          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final choices = json['choices'] as List?;
            if (choices == null || choices.isEmpty) continue;

            final delta =
                choices[0]['delta'] as Map<String, dynamic>? ?? {};

            // Check for thinking/reasoning content
            final reasoning = delta['reasoning_content'] as String? ??
                delta['thinking'] as String?;
            if (reasoning != null && reasoning.isNotEmpty) {
              yield ThinkingDelta(reasoning);
            }

            // Check for regular content
            final content = delta['content'] as String?;
            if (content != null && content.isNotEmpty) {
              yield ContentDelta(content);
            }

            // Check for tool calls
            final toolCalls = delta['tool_calls'] as List?;
            if (toolCalls != null) {
              for (final tc in toolCalls) {
                final tcMap = tc as Map<String, dynamic>;
                final function =
                    tcMap['function'] as Map<String, dynamic>? ?? {};
                yield ToolCallDelta(
                  index: tcMap['index'] as int? ?? 0,
                  id: tcMap['id'] as String?,
                  name: function['name'] as String?,
                  argumentsDelta: function['arguments'] as String? ?? '',
                );
              }
            }
          } catch (e) {
            // Skip malformed JSON lines
            continue;
          }
        }
      }

      yield StreamDone();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        yield StreamDone();
      } else {
        yield StreamError(
            'API error: ${e.response?.statusCode} ${e.message}');
      }
    } catch (e) {
      yield StreamError('Unexpected error: $e');
    }
  }
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);

  @override
  String toString() => message;
}
