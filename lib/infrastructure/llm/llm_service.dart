import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/app_info.dart';
import '../../domain/models/app_settings.dart';
import '../../domain/models/message.dart';
import '../../domain/services/cancellation_token.dart';
import '../../domain/services/i_llm_service.dart';
import 'openai_codec.dart';
import 'sse_think_splitter.dart';

final _log = Logger('LlmService');

/// [ILlmService] over an OpenAI-compatible `chat/completions` endpoint.
class LlmService implements ILlmService {
  final Dio _dio;
  final ApiSettings _apiSettings;
  final GenerationSettings _generationSettings;
  final OpenAiCodec _codec;

  LlmService({
    required Dio dio,
    required ApiSettings apiSettings,
    required GenerationSettings generationSettings,
    OpenAiCodec codec = const OpenAiCodec(),
  }) : _dio = dio,
       _apiSettings = apiSettings,
       _generationSettings = generationSettings,
       _codec = codec;

  /// Factory that creates a production [LlmService] with a configured [Dio].
  factory LlmService.fromSettings({
    required ApiSettings apiSettings,
    required GenerationSettings generationSettings,
  }) {
    return LlmService(
      dio: _createDio(apiSettings),
      apiSettings: apiSettings,
      generationSettings: generationSettings,
    );
  }

  static Dio _createDio(ApiSettings settings) {
    return Dio(
      BaseOptions(
        baseUrl: settings.baseUrl,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': AppInfo.userAgent,
          if (settings.apiKey.isNotEmpty)
            'Authorization': 'Bearer ${settings.apiKey}',
        },
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
  }

  @override
  Future<List<String>> fetchModels() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/models');
      final data = response.data?['data'];
      if (data is! List) {
        throw LlmException('Unexpected /models payload');
      }
      return data.map((m) => (m as Map)['id'] as String).toList()..sort();
    } on DioException catch (e) {
      _log.warning('Failed to fetch models', e);
      throw LlmException('Failed to fetch models: ${e.message}');
    }
  }

  @override
  Stream<StreamEvent> streamChatCompletion({
    required List<Message> history,
    required String systemPrompt,
    ImageBytesMap imageBytes = const {},
    List<McpToolInfo> tools = const [],
    CancellationToken? cancellationToken,
  }) async* {
    if (cancellationToken?.isCancelled ?? false) {
      yield const StreamCancelled();
      return;
    }

    final body = _requestBody(
      messages: _codec.buildMessages(
        history: history,
        systemPrompt: systemPrompt,
        imageBytes: imageBytes,
      ),
      tools: _codec.toolsToApi(tools),
    );

    if (_log.isLoggable(Level.INFO)) {
      _log.info(
        'POST ${_dio.options.baseUrl}/chat/completions\n'
        '${const JsonEncoder.withIndent('  ').convert(_sanitizeForLog(body))}',
      );
    }

    // Map the transport-agnostic token onto Dio's cancel primitive.
    final dioToken = CancelToken();
    unawaited(
      cancellationToken?.whenCancelled.then(
        (_) => dioToken.cancel('cancelled'),
      ),
    );

    // Inline <think>/</think> splitter for servers that put reasoning in
    // `content` (llama.cpp default) instead of a dedicated field.
    final splitter = SseThinkSplitter();

    try {
      final response = await _dio.post<ResponseBody>(
        '/chat/completions',
        data: body,
        options: Options(responseType: ResponseType.stream),
        cancelToken: dioToken,
      );

      final stream = response.data?.stream;
      if (stream == null) {
        yield const StreamError('Empty response body');
        return;
      }
      final sseBuffer = StringBuffer();

      await for (final chunk in stream) {
        if (cancellationToken?.isCancelled ?? false) {
          yield const StreamCancelled();
          return;
        }

        sseBuffer.write(utf8.decode(chunk));
        final lines = sseBuffer.toString().split('\n');
        // Keep the last potentially incomplete line in the buffer.
        sseBuffer
          ..clear()
          ..write(lines.removeLast());

        for (final line in lines) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data: ')) continue;
          final data = trimmed.substring(6);
          if (data == '[DONE]') {
            for (final event in splitter.flush()) {
              yield event;
            }
            yield const StreamDone();
            return;
          }
          for (final event in _parseChunk(data, splitter)) {
            yield event;
          }
        }
      }

      for (final event in splitter.flush()) {
        yield event;
      }
      yield const StreamDone();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        _log.info('Stream cancelled by user');
        yield const StreamCancelled();
      } else {
        final errorBody = await _readErrorBody(e.response);
        _log.severe(
          'API stream error: ${e.response?.statusCode}'
          '${errorBody != null ? '\n$errorBody' : ''}',
          e,
        );
        yield StreamError(
          'API error: ${e.response?.statusCode}'
          '${errorBody != null ? ' — $errorBody' : ' ${e.message}'}',
        );
      }
    } catch (e, st) {
      _log.severe('Unexpected stream error', e, st);
      yield StreamError('Unexpected error: $e');
    }
  }

  Map<String, dynamic> _requestBody({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
  }) {
    final g = _generationSettings;
    return {
      'model': _apiSettings.selectedModel,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'temperature': g.temperature,
      'top_p': g.topP,
      'max_tokens': g.maxTokens,
      'frequency_penalty': g.frequencyPenalty,
      'presence_penalty': g.presencePenalty,
      if (g.topK > 0) 'top_k': g.topK,
      if (g.minP > 0.0) 'min_p': g.minP,
      if (g.repeatPenalty != 1.0) 'repeat_penalty': g.repeatPenalty,
      if (tools.isNotEmpty) ...{'tools': tools, 'tool_choice': 'auto'},
    };
  }

  /// One `data:` line → zero or more events. Malformed lines are skipped.
  Iterable<StreamEvent> _parseChunk(
    String data,
    SseThinkSplitter splitter,
  ) sync* {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(data) as Map<String, dynamic>;
    } on FormatException {
      _log.fine('Skipping malformed SSE JSON line: $data');
      return;
    } on TypeError {
      _log.fine('Skipping non-object SSE JSON line: $data');
      return;
    }

    // Usage arrives on the final chunk (with `stream_options.include_usage`).
    final usage = json['usage'];
    if (usage is Map) {
      yield StreamUsage(
        promptTokens: usage['prompt_tokens'] as int? ?? 0,
        completionTokens: usage['completion_tokens'] as int? ?? 0,
      );
    }

    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return;
    final delta = (choices[0] as Map)['delta'];
    if (delta is! Map) return;

    // Reasoning on a dedicated field:
    // - reasoning_content: DeepSeek-style
    // - thinking: Anthropic-style
    // - reasoning: mlx_vlm server (Qwen with --enable-thinking)
    final reasoning =
        delta['reasoning_content'] as String? ??
        delta['thinking'] as String? ??
        delta['reasoning'] as String?;
    if (reasoning != null && reasoning.isNotEmpty) {
      yield ThinkingDelta(reasoning);
    }

    final content = delta['content'] as String?;
    if (content != null && content.isNotEmpty) {
      yield* splitter.push(content);
    }

    final toolCalls = delta['tool_calls'];
    if (toolCalls is List) {
      for (final tc in toolCalls) {
        final tcMap = tc as Map;
        final function = tcMap['function'] as Map? ?? const {};
        yield ToolCallDelta(
          index: tcMap['index'] as int? ?? 0,
          id: tcMap['id'] as String?,
          name: function['name'] as String?,
          argumentsDelta: function['arguments'] as String? ?? '',
        );
      }
    }
  }

  /// When responseType is stream, `response.data` is a `ResponseBody`
  /// whose `stream` must be drained to recover the server's error payload.
  static Future<String?> _readErrorBody(Response<dynamic>? response) async {
    final data = response?.data;
    if (data == null) return null;
    try {
      if (data is ResponseBody) {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in data.stream) {
          builder.add(chunk);
        }
        final text = utf8
            .decode(builder.takeBytes(), allowMalformed: true)
            .trim();
        return text.isEmpty ? null : text;
      }
      if (data is String) return data.isEmpty ? null : data;
      return data.toString();
    } catch (_) {
      return null;
    }
  }

  /// Replace large base64 strings with a short summary for logging.
  static Object? _sanitizeForLog(Object? value) {
    if (value is String && value.startsWith('data:') && value.length > 200) {
      final sizeKb = (value.length * 3 / 4 / 1024).round();
      return '<base64 ~${sizeKb}KB>';
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k, _sanitizeForLog(v)));
    }
    if (value is List) {
      return value.map(_sanitizeForLog).toList();
    }
    return value;
  }
}
