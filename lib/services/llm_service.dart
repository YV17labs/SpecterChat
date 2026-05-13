import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../models/app_settings.dart';
import 'i_llm_service.dart';

export 'i_llm_service.dart' show
    StreamEvent, ContentDelta, ThinkingDelta,
    ToolCallDelta, StreamDone, StreamError;

final _log = Logger('LlmService');

/// Service for communicating with OpenAI-compatible LLM APIs.
class LlmService implements ILlmService {
  final Dio _dio;
  final ApiSettings _apiSettings;
  final GenerationSettings _generationSettings;

  LlmService({
    required Dio dio,
    required ApiSettings apiSettings,
    required GenerationSettings generationSettings,
  })  : _dio = dio,
        _apiSettings = apiSettings,
        _generationSettings = generationSettings;

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

  @override
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
      _log.warning('Failed to fetch models', e);
      throw LlmException('Failed to fetch models: ${e.message}');
    }
  }

  @override
  Stream<StreamEvent> streamChatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async* {
    // Per-stream state for the inline <think>/</think> splitter on `content`.
    // We support two formats:
    //   1. Reasoning sent on a separate field (reasoning_content / thinking
    //      / reasoning) — handled directly below, no state needed.
    //   2. Inline <think>...</think> markers inside `content` itself
    //      (llama.cpp default, some OpenAI-compatible servers). Both tags
    //      come from the model's generation, so we always see the opener.
    bool inThinking = false;
    String thinkBuf = '';
    const openTag = '<think>';
    const closeTag = '</think>';

    final body = <String, dynamic>{
      'model': _apiSettings.selectedModel,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'temperature': _generationSettings.temperature,
      'top_p': _generationSettings.topP,
      'max_tokens': _generationSettings.maxTokens,
      'frequency_penalty': _generationSettings.frequencyPenalty,
      'presence_penalty': _generationSettings.presencePenalty,
    };

    if (_generationSettings.topK > 0) {
      body['top_k'] = _generationSettings.topK;
    }
    if (_generationSettings.minP > 0.0) {
      body['min_p'] = _generationSettings.minP;
    }
    if (_generationSettings.repeatPenalty != 1.0) {
      body['repeat_penalty'] = _generationSettings.repeatPenalty;
    }
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    if (_log.isLoggable(Level.INFO)) {
      _log.info('POST ${_dio.options.baseUrl}/chat/completions\n'
          '${const JsonEncoder.withIndent('  ').convert(_sanitizeForLog(body))}');
    }

    try {
      final response = await _dio.post(
        '/chat/completions',
        data: body,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );

      final stream = response.data.stream as Stream<List<int>>;
      final sseBuffer = StringBuffer();

      await for (final chunk in stream) {
        if (cancelToken?.isCancelled ?? false) break;

        sseBuffer.write(utf8.decode(chunk));
        final accumulated = sseBuffer.toString();
        final lines = accumulated.split('\n');
        // Keep the last potentially incomplete line in the buffer.
        sseBuffer
          ..clear()
          ..write(lines.removeLast());

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data: ')) continue;

          final data = trimmed.substring(6);
          if (data == '[DONE]') {
            if (thinkBuf.isNotEmpty) {
              yield inThinking
                  ? ThinkingDelta(thinkBuf)
                  : ContentDelta(thinkBuf);
              thinkBuf = '';
            }
            yield StreamDone();
            return;
          }

          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            // Parse usage info from the final chunk.
            final usage = json['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              yield StreamUsage(
                promptTokens: usage['prompt_tokens'] as int? ?? 0,
                completionTokens: usage['completion_tokens'] as int? ?? 0,
              );
            }

            final choices = json['choices'] as List?;
            if (choices == null || choices.isEmpty) continue;

            final delta =
                choices[0]['delta'] as Map<String, dynamic>? ?? {};

            // Check for thinking/reasoning content
            // - reasoning_content: DeepSeek-style
            // - thinking: Anthropic-style
            // - reasoning: mlx_vlm server (Qwen with --enable-thinking)
            final reasoning = delta['reasoning_content'] as String? ??
                delta['thinking'] as String? ??
                delta['reasoning'] as String?;
            if (reasoning != null && reasoning.isNotEmpty) {
              yield ThinkingDelta(reasoning);
            }

            // Inline <think>/</think> splitter on `content` — see the
            // comment at the top of streamChatCompletion for the cases.
            final content = delta['content'] as String?;
            if (content != null && content.isNotEmpty) {
              thinkBuf += content;
              while (true) {
                if (inThinking) {
                  final idx = thinkBuf.indexOf(closeTag);
                  if (idx >= 0) {
                    if (idx > 0) {
                      yield ThinkingDelta(thinkBuf.substring(0, idx));
                    }
                    // Strip the blank line some models emit after </think>.
                    thinkBuf = thinkBuf
                        .substring(idx + closeTag.length)
                        .replaceFirst(RegExp(r'^\n{1,2}'), '');
                    inThinking = false;
                    continue;
                  }
                  final hold = _partialTagSuffixLen(thinkBuf, closeTag);
                  final safe = thinkBuf.length - hold;
                  if (safe > 0) {
                    yield ThinkingDelta(thinkBuf.substring(0, safe));
                    thinkBuf = thinkBuf.substring(safe);
                  }
                  break;
                } else {
                  final idx = thinkBuf.indexOf(openTag);
                  if (idx >= 0) {
                    if (idx > 0) {
                      yield ContentDelta(thinkBuf.substring(0, idx));
                    }
                    thinkBuf = thinkBuf.substring(idx + openTag.length);
                    inThinking = true;
                    continue;
                  }
                  // No opening tag — emit safe portion, hold back any
                  // trailing chars that could be the start of a tag so a
                  // tag spanning two deltas is still caught next pass.
                  final hold = _partialTagSuffixLen(thinkBuf, openTag);
                  final safe = thinkBuf.length - hold;
                  if (safe > 0) {
                    yield ContentDelta(thinkBuf.substring(0, safe));
                    thinkBuf = thinkBuf.substring(safe);
                  }
                  break;
                }
              }
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
            _log.fine('Skipping malformed SSE JSON line: $data');
            continue;
          }
        }
      }

      if (thinkBuf.isNotEmpty) {
        yield inThinking ? ThinkingDelta(thinkBuf) : ContentDelta(thinkBuf);
        thinkBuf = '';
      }
      yield StreamDone();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        _log.info('Stream cancelled by user');
        yield StreamDone();
      } else {
        final body = await _readErrorBody(e.response);
        _log.severe(
            'API stream error: ${e.response?.statusCode}${body != null ? '\n$body' : ''}',
            e);
        yield StreamError(
            'API error: ${e.response?.statusCode}${body != null ? ' — $body' : ' ${e.message}'}');
      }
    } catch (e, st) {
      _log.severe('Unexpected stream error', e, st);
      yield StreamError('Unexpected error: $e');
    }
  }

  /// Longest suffix of [s] that is also a prefix of [tag]. Used to decide
  /// how many trailing chars of the content buffer to hold back so that a
  /// `<think>` or `</think>` tag spanning two streamed deltas is still
  /// detected on the next pass.
  static int _partialTagSuffixLen(String s, String tag) {
    final maxLen = s.length < tag.length - 1 ? s.length : tag.length - 1;
    for (var n = maxLen; n > 0; n--) {
      if (s.endsWith(tag.substring(0, n))) return n;
    }
    return 0;
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
        final text = utf8.decode(builder.takeBytes(), allowMalformed: true).trim();
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

class LlmException implements Exception {
  final String message;
  LlmException(this.message);

  @override
  String toString() => message;
}
