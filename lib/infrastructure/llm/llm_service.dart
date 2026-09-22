import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/app_info.dart';
import '../../domain/chat_session_state.dart' show GenerationProgress;
import '../../domain/models/app_settings.dart';
import '../../domain/models/message.dart';
import '../../domain/models/model_info.dart';
import '../../domain/models/request_profile.dart';
import '../../domain/services/cancellation_token.dart';
import '../../domain/services/i_llm_service.dart';
import 'openai_codec.dart';
import 'sse_think_splitter.dart';

final _log = Logger('LlmService');

/// [ILlmService] over an OpenAI-compatible `chat/completions` endpoint.
///
/// Holds only what identifies the connection (client, base URL, selected
/// model). What a request carries beyond the messages comes with each call
/// as a [RequestProfile], so changing a sampling slider never rebuilds the
/// HTTP client and an in-flight turn keeps the profile it started with.
class LlmService implements ILlmService {
  final Dio _dio;
  final ApiSettings _apiSettings;
  final OpenAiCodec _codec;

  LlmService({
    required Dio dio,
    required ApiSettings apiSettings,
    OpenAiCodec codec = const OpenAiCodec(),
  }) : _dio = dio,
       _apiSettings = apiSettings,
       _codec = codec;

  /// Factory that creates a production [LlmService] with a configured [Dio].
  factory LlmService.fromSettings({required ApiSettings apiSettings}) {
    return LlmService(dio: _createDio(apiSettings), apiSettings: apiSettings);
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
  String get model => _apiSettings.selectedModel;

  @override
  String get endpoint => _dio.options.baseUrl;

  @override
  Future<List<ModelInfo>> fetchModels() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/models');
      final data = response.data?['data'];
      if (data is! List) {
        throw LlmException('Unexpected /models payload');
      }
      final models = <ModelInfo>[];
      for (final entry in data) {
        if (entry is! Map) continue;
        try {
          models.add(
            OpenAiCodec.parseModelInfo(Map<String, dynamic>.from(entry)),
          );
        } on FormatException catch (e) {
          _log.fine('Skipping model entry: $e');
        }
      }
      return models..sort((a, b) => a.id.compareTo(b.id));
    } on DioException catch (e) {
      _log.warning('Failed to fetch models', e);
      throw LlmException('Failed to fetch models: ${e.message}');
    }
  }

  @override
  Stream<StreamEvent> streamChatCompletion({
    required List<Message> history,
    required String systemPrompt,
    RequestProfile profile = const TextRequestProfile(),
    ImageBytesMap imageBytes = const {},
    List<McpToolInfo> tools = const [],
    CancellationToken? cancellationToken,
  }) async* {
    if (cancellationToken?.isCancelled ?? false) {
      yield const StreamCancelled();
      return;
    }

    final body = _codec.requestBody(
      model: _apiSettings.selectedModel,
      profile: profile,
      history: history,
      systemPrompt: systemPrompt,
      imageBytes: imageBytes,
      tools: tools,
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

    final chunks = _ChunkReader();

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

      // Decode through a streaming decoder so a multi-byte character split
      // across two chunks is not turned into replacement glyphs.
      await for (final chunk in utf8.decoder.bind(stream)) {
        if (cancellationToken?.isCancelled ?? false) {
          yield const StreamCancelled();
          return;
        }

        sseBuffer.write(chunk);
        // A single `data:` line can be several MB (a base64 image). Only
        // re-scan the buffer when a line may have completed — otherwise
        // every network packet would copy and split the whole buffer.
        if (!chunk.contains('\n')) continue;
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
            for (final event in chunks.splitter.flush()) {
              yield event;
            }
            yield const StreamDone();
            return;
          }
          await for (final event in _parseChunk(data, chunks)) {
            yield event;
          }
        }
      }

      for (final event in chunks.splitter.flush()) {
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

  /// One `data:` line → zero or more events. Malformed lines are skipped.
  ///
  /// Async because an `images` entry may carry an http(s) URL that has to
  /// be fetched before it can be handed over as bytes.
  Stream<StreamEvent> _parseChunk(String data, _ChunkReader chunks) async* {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(data) as Map<String, dynamic>;
    } on FormatException {
      _log.fine('Skipping malformed SSE JSON line: ${_truncate(data)}');
      return;
    } on TypeError {
      _log.fine('Skipping non-object SSE JSON line: ${_truncate(data)}');
      return;
    }

    // A server that fails after the stream started sends the OpenAI error
    // envelope as an event instead of an HTTP status.
    final error = json['error'];
    if (error != null) {
      final message = error is Map
          ? error['message'] as String? ?? error.toString()
          : error.toString();
      yield StreamError('API error: $message');
      return;
    }

    if (chunks.report(json) case final fields?) yield ServerReport(fields);

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
      yield* Stream.fromIterable(chunks.splitter.push(content));
    }

    // Extension: long-running server step (image generation).
    final progress = delta['progress'];
    if (progress is Map) {
      final stage = progress['stage'] as String?;
      if (stage != null && stage.isNotEmpty) {
        yield ProgressDelta(
          GenerationProgress(
            stage: stage,
            step: (progress['step'] as num?)?.toInt(),
            total: (progress['total'] as num?)?.toInt(),
            percent: (progress['percent'] as num?)?.toInt(),
            message: progress['message'] as String?,
          ),
        );
      }
    }

    // Images produced by the assistant (OpenRouter `images` convention).
    for (final generated in OpenAiCodec.generatedImages(delta['images'])) {
      final image = await _resolveImageUrl(generated.url);
      if (image == null) continue;
      yield ImageDelta(
        bytes: image.bytes,
        mimeType: image.mimeType,
        textToImage: generated.textToImage,
      );
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

  /// Bytes for an image URL: inline for `data:` URLs, fetched for
  /// http(s) ones (relative paths resolve against the API base URL, which
  /// is how the server refers back to its own `/v1/files/…`).
  Future<ImageBytes?> _resolveImageUrl(String url) async {
    final inline = OpenAiCodec.decodeDataUrl(url);
    if (inline != null) return inline;
    if (!url.startsWith('http://') &&
        !url.startsWith('https://') &&
        !url.startsWith('/')) {
      _log.fine('Ignoring image URL with unsupported scheme');
      return null;
    }
    try {
      final target = url.startsWith('/')
          ? Uri.parse(_dio.options.baseUrl).replace(path: url).toString()
          : url;
      final response = await _dio.get<List<int>>(
        target,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      final mime =
          response.headers.value('content-type')?.split(';').first.trim() ??
          'image/png';
      // Dio already hands back a Uint8List for `ResponseType.bytes`.
      return (
        bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        mimeType: mime,
      );
    } on DioException catch (e) {
      _log.warning('Failed to fetch image $url', e);
      return null;
    }
  }

  static String _truncate(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s;

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

/// Per-stream state of the SSE parser.
class _ChunkReader {
  /// Inline `<think>`/`</think>` splitter for servers that put reasoning in
  /// `content` (llama.cpp default) instead of a dedicated field.
  final splitter = SseThinkSplitter();

  bool _envelopeReported = false;

  /// Keys every chunk repeats: reported once, from the first chunk.
  static const _envelope = {
    'id',
    'object',
    'created',
    'model',
    'system_fingerprint',
  };

  /// What [chunk] says about the turn besides its deltas, verbatim, or
  /// `null` when it says nothing new — most chunks. `null` values are
  /// skipped: OpenAI sends `"usage": null` on every chunk but the last.
  Map<String, dynamic>? report(Map<String, dynamic> chunk) {
    final first = !_envelopeReported;
    _envelopeReported = true;
    final fields = <String, dynamic>{
      for (final MapEntry(:key, :value) in chunk.entries)
        if (key != 'choices' &&
            value != null &&
            (first || !_envelope.contains(key)))
          key: value,
    };
    if (chunk['choices'] case [{'finish_reason': final Object reason}, ...]) {
      fields['finish_reason'] = reason;
    }
    return fields.isEmpty ? null : fields;
  }
}
