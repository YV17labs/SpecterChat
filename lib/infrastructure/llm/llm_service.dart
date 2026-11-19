import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/app_info.dart';
import '../../core/image_mime.dart';
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

/// [ILlmService] over an OpenAI-compatible server: `chat/completions`,
/// and `images/generations` for a model asked through the Images API.
///
/// Holds only what identifies the connection (client, base URL, selected
/// model). What a request carries beyond the messages comes with each call
/// as a [RequestProfile], so changing a sampling slider never rebuilds the
/// HTTP client and an in-flight turn keeps the profile it started with.
class LlmService implements ILlmService {
  final Dio _dio;
  final ApiSettings _apiSettings;
  final OpenAiCodec _codec;

  /// How long an Images API answer may stay silent. The client's five
  /// minutes suit a chat that streams tokens; a picture can take longer
  /// with nothing to say meanwhile — a server that does not stream sends
  /// its first byte once it is drawn. Stop ends a turn that hangs.
  static const _imagesReceiveTimeout = Duration(minutes: 30);

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

    if (profile case ImageRequestProfile(api: ImageApi.imagesEndpoint)) {
      yield* _streamImages(
        history: history,
        profile: profile,
        imageBytes: imageBytes,
        cancellationToken: cancellationToken,
      );
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
    final chunks = _ChunkReader();
    yield* _postEvents(
      '/chat/completions',
      body,
      cancellationToken,
      onData: (data) => _parseChunk(data, chunks),
      onEnd: chunks.splitter.flush,
    );
  }

  /// One turn of an [ImageApi.imagesEndpoint] model:
  /// `POST /images/generations`, streamed. mlx-serve answers with typed
  /// events — `progress` (`stage`, `step`, `total`), then `complete`
  /// carrying the non-streamed body (`data[]`), or `error`; a server that
  /// ignores `stream` sends that body alone.
  ///
  /// The API has one thing to give, so an answer without it is a failure
  /// and not a turn that said nothing: an empty `data`, a picture in a
  /// format the app does not read, a page that is not the API at all —
  /// each would otherwise end as a reply with nothing in it, no error
  /// shown.
  Stream<StreamEvent> _streamImages({
    required List<Message> history,
    required ImageRequestProfile profile,
    required ImageBytesMap imageBytes,
    required CancellationToken? cancellationToken,
  }) async* {
    final Map<String, dynamic> body;
    try {
      body = _codec.imagesRequestBody(
        model: _apiSettings.selectedModel,
        profile: profile,
        history: history,
        imageBytes: imageBytes,
      );
    } on UnsendableImageRequest catch (e) {
      yield StreamError(e.message);
      return;
    }
    // What was sent decides it: the API never says.
    final textToImage = !body.containsKey('image');
    final events = _postEvents(
      '/images/generations',
      body,
      cancellationToken,
      receiveTimeout: _imagesReceiveTimeout,
      onData: (data) => _parseImagesEvent(data, textToImage: textToImage),
      onBody: (text) => _parseImagesEvent(text, textToImage: textToImage),
    );
    var pictures = 0;
    await for (final event in events) {
      if (event is ImageDelta) pictures++;
      if (event is StreamDone && pictures == 0) {
        yield const StreamError('The server answered without a picture.');
        return;
      }
      yield event;
    }
  }

  /// [body] POSTed to [path], the answer read as server-sent events:
  /// [onData] turns each `data:` payload into events, [onEnd] gives what
  /// is still buffered once the stream ends (`[DONE]` or the end of the
  /// body), and [onBody] reads a body that holds no event at all — a
  /// server that ignores `stream` answers with one JSON document.
  ///
  /// Every endpoint ends the same way, on exactly one terminal event:
  /// cancellation, a transport error and a parser that throws all come
  /// out as one, and an error is the end whatever the server sends after
  /// it. This stream itself never fails.
  Stream<StreamEvent> _postEvents(
    String path,
    Map<String, dynamic> body,
    CancellationToken? cancellationToken, {
    required Stream<StreamEvent> Function(String data) onData,
    Iterable<StreamEvent> Function() onEnd = _nothing,
    Stream<StreamEvent> Function(String body)? onBody,
    Duration? receiveTimeout,
  }) async* {
    if (_log.isLoggable(Level.INFO)) {
      _log.info(
        'POST ${_dio.options.baseUrl}$path\n'
        '${const JsonEncoder.withIndent('  ').convert(_sanitizeForLog(body))}',
      );
    }

    try {
      final events = _readEvents(
        path,
        body,
        cancellationToken,
        onData: onData,
        onEnd: onEnd,
        onBody: onBody,
        receiveTimeout: receiveTimeout,
      );
      // `await for`, never `yield*`: that hands a stream's error straight
      // to the listener, past the `catch` below, and the turn would never
      // end — its row left as still streaming.
      await for (final event in events) {
        yield event;
        if (event is StreamError) return;
      }
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

  /// The request behind [_postEvents] and the reading of its answer,
  /// with nothing caught: a transport error or a parser that throws
  /// fails this stream, and [_postEvents] turns that into an event.
  Stream<StreamEvent> _readEvents(
    String path,
    Map<String, dynamic> body,
    CancellationToken? cancellationToken, {
    required Stream<StreamEvent> Function(String data) onData,
    required Iterable<StreamEvent> Function() onEnd,
    required Stream<StreamEvent> Function(String body)? onBody,
    required Duration? receiveTimeout,
  }) async* {
    // Map the transport-agnostic token onto Dio's cancel primitive.
    final dioToken = CancelToken();
    unawaited(
      cancellationToken?.whenCancelled.then(
        (_) => dioToken.cancel('cancelled'),
      ),
    );

    final response = await _dio.post<ResponseBody>(
      path,
      data: body,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: receiveTimeout,
      ),
      cancelToken: dioToken,
    );

    final stream = response.data?.stream;
    if (stream == null) {
      yield const StreamError('Empty response body');
      return;
    }
    final sseBuffer = StringBuffer();
    // The body as it came, kept for [onBody] until an event shows up.
    final plain = onBody == null ? null : StringBuffer();
    var sawEvent = false;

    // `null` once `[DONE]` has been read. The space after `data:` is
    // optional in server-sent events, and not every server writes it.
    Stream<StreamEvent>? readLine(String line) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) {
        if (!sawEvent) plain?.writeln(line);
        return const Stream.empty();
      }
      sawEvent = true;
      final data = trimmed.substring(5).trimLeft();
      return data == '[DONE]' ? null : onData(data);
    }

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
        final events = readLine(line);
        if (events == null) {
          yield* Stream.fromIterable(onEnd());
          yield const StreamDone();
          return;
        }
        yield* events;
      }
    }

    // The last line need not end with a newline.
    final events = readLine(sseBuffer.toString());
    if (events != null) yield* events;
    if (!sawEvent && plain != null && plain.toString().trim().isNotEmpty) {
      yield* onBody!(plain.toString());
    }
    yield* Stream.fromIterable(onEnd());
    yield const StreamDone();
  }

  static Iterable<StreamEvent> _nothing() => const [];

  /// [data] as a JSON object; `null`, and skipped, when it is not one.
  static Map<String, dynamic>? _decodeEvent(String data) {
    try {
      return jsonDecode(data) as Map<String, dynamic>;
    } on FormatException {
      _log.fine('Skipping malformed event: ${_truncate(data)}');
    } on TypeError {
      _log.fine('Skipping non-object event: ${_truncate(data)}');
    }
    return null;
  }

  /// What an event that reports a failure says: the OpenAI envelope
  /// (`{"error": {"message": …}}`), a bare `error` value, or the
  /// `message` of an event typed `error`.
  static String _errorMessage(Map<String, dynamic> event) =>
      switch (event['error']) {
        {'message': final String message} => message,
        null => switch (event['message']) {
          final String message => message,
          _ => 'unknown error',
        },
        final error => '$error',
      };

  /// A server's progress report, read leniently: it is shown and
  /// forgotten, so a field of another type is left out rather than
  /// failing the turn. A `total` of 0 is a server's "indeterminate".
  static GenerationProgress _progressFrom(
    Map<dynamic, dynamic> report, {
    required String stage,
  }) {
    int? integer(Object? value) => value is num ? value.toInt() : null;
    final total = integer(report['total']);
    final message = report['message'];
    return GenerationProgress(
      stage: stage,
      step: integer(report['step']),
      total: total == 0 ? null : total,
      percent: integer(report['percent']),
      message: message is String ? message : null,
    );
  }

  /// One event of an Images API answer (or the whole answer of a server
  /// that does not stream) → zero or more events. Malformed ones are
  /// skipped. [textToImage] is whether the request carried no image.
  Stream<StreamEvent> _parseImagesEvent(
    String data, {
    required bool textToImage,
  }) async* {
    final json = _decodeEvent(data);
    if (json == null) return;

    if (json['type'] == 'error' || json['error'] != null) {
      yield StreamError('API error: ${_errorMessage(json)}');
      return;
    }

    if (json['type'] == 'progress') {
      final stage = json['stage'];
      yield ProgressDelta(
        _progressFrom(json, stage: stage is String ? stage : 'generating'),
      );
      return;
    }

    // The answer — a closing event, or the whole body of a server that
    // does not stream. Everything in it but the pictures is a report on
    // the turn; the pictures are megabytes of base64, never part of it.
    final report = {
      for (final MapEntry(:key, :value) in json.entries)
        if (key != 'type' &&
            value != null &&
            !OpenAiCodec.imagesPictureKeys.contains(key))
          key: value,
    };
    if (report.isNotEmpty) yield ServerReport(report);
    for (final picture in OpenAiCodec.imagesResponseData(json)) {
      final image = picture.url != null
          ? await _resolveImageUrl(picture.url!)
          : _decodeBase64Image(picture.base64!);
      if (image == null) continue;
      yield ImageDelta(
        bytes: image.bytes,
        mimeType: image.mimeType,
        textToImage: textToImage,
      );
    }
  }

  /// A `b64_json` picture, its type read from its bytes; `null` when it is
  /// not base64 or not an image the app takes.
  static ImageBytes? _decodeBase64Image(String base64) {
    try {
      final bytes = base64Decode(base64.trim());
      final mime = sniffImageMime(bytes);
      if (mime == null) {
        _log.warning('Image of unknown format in the answer, skipped');
        return null;
      }
      return (bytes: bytes, mimeType: mime);
    } on FormatException {
      _log.warning('Malformed base64 image in the answer, skipped');
      return null;
    }
  }

  /// One `data:` line → zero or more events. Malformed lines are skipped.
  ///
  /// Async because an `images` entry may carry an http(s) URL that has to
  /// be fetched before it can be handed over as bytes.
  Stream<StreamEvent> _parseChunk(String data, _ChunkReader chunks) async* {
    final json = _decodeEvent(data);
    if (json == null) return;

    // A server that fails after the stream started sends the OpenAI error
    // envelope as an event instead of an HTTP status.
    if (json['error'] != null) {
      yield StreamError('API error: ${_errorMessage(json)}');
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
    if (delta['progress'] case final Map<dynamic, dynamic> progress) {
      if (progress['stage'] case final String stage when stage.isNotEmpty) {
        yield ProgressDelta(_progressFrom(progress, stage: stage));
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
  ///
  /// The API key goes to the API server and nowhere else. A picture kept
  /// on another host — a CDN, a storage bucket, which is where the Images
  /// API's `url` answers usually point — is fetched without it, the way
  /// an HTTP client drops credentials when a redirect leaves the origin.
  Future<ImageBytes?> _resolveImageUrl(String url) async {
    final inline = OpenAiCodec.decodeDataUrl(url);
    if (inline != null) return inline;
    final base = Uri.tryParse(_dio.options.baseUrl);
    final target = url.startsWith('/')
        ? base?.replace(path: url)
        : Uri.tryParse(url);
    if (target == null || !const {'http', 'https'}.contains(target.scheme)) {
      _log.fine('Ignoring image URL with unsupported scheme');
      return null;
    }
    try {
      final response = await _dio.getUri<List<int>>(
        target,
        options: Options(
          responseType: ResponseType.bytes,
          // A `null` value takes the client's default header off.
          headers: base != null && _sameOrigin(target, base)
              ? null
              : {'Authorization': null},
        ),
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

  /// Same scheme, host and port: what a credential is scoped to.
  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

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

  /// How a bare base64 string starts: 200 characters of its alphabet and
  /// nothing else. Text does not — it has spaces or, written in a script
  /// that uses none, characters outside that alphabet; a URL has its
  /// `:`, JSON its braces and quotes.
  static final _base64Head = RegExp('^[A-Za-z0-9+/_-]{200}');

  /// Replace large base64 strings — data URLs, and the bare base64 of an
  /// Images API body — with a short summary for logging.
  static Object? _sanitizeForLog(Object? value) {
    if (value is String &&
        value.length > 200 &&
        (value.startsWith('data:') || _base64Head.hasMatch(value))) {
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
