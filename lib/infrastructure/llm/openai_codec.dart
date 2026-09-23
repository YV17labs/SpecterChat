import 'dart:convert';

import '../../domain/models/app_settings.dart';
import '../../domain/models/image_settings.dart';
import '../../domain/models/message.dart';
import '../../domain/models/model_info.dart';
import '../../domain/models/request_profile.dart';
import 'schema_inliner.dart';

/// Where the images an assistant turn carries go on the wire.
///
/// The OpenAI schema takes an `image_url` content part on a `user`
/// message only; an assistant message takes `text` and `refusal` parts.
/// A generated image still has to come back on the next request for
/// "now make it blue" to edit it, so it travels in a message of its own.
enum AssistantImagePlacement {
  /// The images follow their turn in a `user` message — after its tool
  /// results if it called tools, since nothing may come between a
  /// `tool_calls` message and the results that answer it.
  followingUserMessage,

  /// `image_url` parts on the assistant message itself. What the image
  /// server asks for: it keeps nothing between requests and edits what
  /// the client re-sends on the assistant turn (`../pictor/PROTOCOL.md`).
  inline,
}

/// Translates domain messages and tools into the OpenAI chat/completions
/// wire format. The only place in the app that knows what an
/// `image_url` part or a `tool_calls` array looks like.
class OpenAiCodec {
  const OpenAiCodec();

  /// The whole `chat/completions` body for one streaming request.
  ///
  /// Everything beyond `model` + `messages` depends on [profile]: a text
  /// model gets its sampling parameters, the system prompt and the tools;
  /// an image server gets the `generation` options object and neither a
  /// system prompt nor tools — it ignores both, and leaving them out keeps
  /// the request small and unambiguous, and it reads a generated image
  /// back on the assistant turn that made it
  /// ([AssistantImagePlacement.inline]). A new kind of backend is a new
  /// profile and a new case here, nothing else.
  ///
  /// The text body is written for the local OpenAI-compatible servers this
  /// app targets rather than for api.openai.com: `top_k`, `min_p` and
  /// `repeat_penalty` are not in the OpenAI schema at all, and the token
  /// cap goes out under its deprecated name `max_tokens` — the only one
  /// every one of those servers reads.
  Map<String, dynamic> requestBody({
    required String model,
    required RequestProfile profile,
    required List<Message> history,
    required String systemPrompt,
    ImageBytesMap imageBytes = const {},
    List<McpToolInfo> tools = const [],
  }) {
    switch (profile) {
      case TextRequestProfile(generation: final g):
        final toolsApi = toolsToApi(tools);
        return {
          'model': model,
          'messages': buildMessages(
            history: history,
            systemPrompt: systemPrompt,
            imageBytes: imageBytes,
          ),
          'stream': true,
          'stream_options': {'include_usage': true},
          'temperature': g.temperature,
          'top_p': g.topP,
          // Ollama reads no other name (`openai/openai.go`) and silently
          // generates without a limit when it is missing; see above.
          'max_tokens': g.maxTokens,
          'frequency_penalty': g.frequencyPenalty,
          'presence_penalty': g.presencePenalty,
          if (g.topK > 0) 'top_k': g.topK,
          if (g.minP > 0.0) 'min_p': g.minP,
          if (g.repeatPenalty != 1.0) 'repeat_penalty': g.repeatPenalty,
          if (toolsApi.isNotEmpty) ...{
            'tools': toolsApi,
            'tool_choice': 'auto',
          },
        };
      case ImageRequestProfile(:final image):
        final options = imageOptionsToApi(image);
        return {
          'model': model,
          'messages': buildMessages(
            history: history,
            systemPrompt: '',
            imageBytes: imageBytes,
            assistantImages: AssistantImagePlacement.inline,
          ),
          'stream': true,
          if (options.isNotEmpty) 'generation': options,
        };
    }
  }

  /// The messages array for one request. What this builds is what the
  /// conversation export's `guide.whatTheModelSees` describes — keep the
  /// two in step.
  ///
  ///
  /// [imageBytes] carries preloaded bytes for every image attachment
  /// referenced by [history]. The base64 string is materialised here,
  /// handed to the HTTP client, and freed as soon as the body is
  /// serialised.
  List<Map<String, dynamic>> buildMessages({
    required List<Message> history,
    required String systemPrompt,
    ImageBytesMap imageBytes = const {},
    AssistantImagePlacement assistantImages =
        AssistantImagePlacement.followingUserMessage,
  }) {
    final skip = _indicesWithBrokenToolCalls(history);
    final messages = <Map<String, dynamic>>[];

    if (systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }

    // Images that travel apart, see [AssistantImagePlacement]. They wait
    // here and go out as one user message at the next point where a user
    // message may be inserted — never between an assistant `tool_calls`
    // message and the results the spec requires to follow it directly.
    var displacedImageParts = <Map<String, dynamic>>[];

    void displace(String attachmentId, String provenance) {
      final loaded = imageBytes[attachmentId];
      if (loaded == null) return;
      displacedImageParts
        ..add(imageUrlPart(loaded))
        ..add({'type': 'text', 'text': provenance});
    }

    for (var i = 0; i < history.length; i++) {
      if (skip.contains(i)) continue;
      final msg = history[i];

      // One split, so what leaves the message and what is re-emitted just
      // below are the same list: each image goes out exactly once.
      final split =
          msg.role == MessageRole.assistant &&
              assistantImages == AssistantImagePlacement.followingUserMessage
          ? _splitImageBlocks(msg)
          : (message: msg, displaced: const <ImageContentBlock>[]);

      messages.add(messageToApi(split.message, imageBytes));

      for (final image in split.displaced) {
        displace(
          image.attachmentId,
          'Image generated by the assistant on the turn above.',
        );
      }

      // A tool message holds text only, whatever the placement.
      if (msg.role == MessageRole.tool) {
        for (final result in msg.content.whereType<ToolResultContentBlock>()) {
          for (final image
              in result.resultContent.whereType<ImageContentBlock>()) {
            displace(
              image.attachmentId,
              'Image result from tool "${result.toolName}".',
            );
          }
        }
      }

      if (displacedImageParts.isNotEmpty) {
        final canInsertUserMessage =
            i + 1 >= history.length || history[i + 1].role != MessageRole.tool;
        if (canInsertUserMessage) {
          messages.add({'role': 'user', 'content': displacedImageParts});
          displacedImageParts = <Map<String, dynamic>>[];
        }
      }
    }

    return messages;
  }

  /// One entry of `GET /models` as a [ModelInfo].
  ///
  /// An image-generation server (Pictor) tags its models with a
  /// `generation` object whose `kind` is `"image"` (`specterforge` before
  /// protocol 0.3.0, still honoured); anything else — a plain OpenAI list,
  /// another vendor's extension, a malformed block — is a text LLM.
  /// Missing sub-objects fall back to the model defaults so an older
  /// server still yields a usable description.
  static ModelInfo parseModelInfo(Map<String, dynamic> entry) {
    final id = entry['id'];
    if (id is! String) throw const FormatException('model entry without id');
    final forge = entry['generation'] ?? entry['specterforge'];
    if (forge is! Map || forge['kind'] != 'image') return ModelInfo(id: id);
    final json = Map<String, dynamic>.from(forge);
    return ModelInfo(
      id: id,
      image: ImageModelInfo(
        backend: json['backend'] is String ? json['backend'] as String : '',
        device: json['device'] is String ? json['device'] as String : '',
        capabilities: _section(
          json['capabilities'],
          _capabilitiesFromApi,
          const ImageCapabilities(),
        ),
        defaults: _section(
          json['defaults'],
          _defaultsFromApi,
          const ImageDefaults(),
        ),
      ),
    );
  }

  static T _section<T>(
    Object? raw,
    T Function(Map<String, dynamic>) parse,
    T fallback,
  ) {
    if (raw is! Map) return fallback;
    try {
      return parse(Map<String, dynamic>.from(raw));
    } on TypeError {
      return fallback;
    }
  }

  static ImageCapabilities _capabilitiesFromApi(Map<String, dynamic> c) {
    const d = ImageCapabilities();
    return ImageCapabilities(
      textToImage: c['text_to_image'] as bool? ?? d.textToImage,
      referenceEdit: c['reference_edit'] as bool? ?? d.referenceEdit,
      maxReferenceImages:
          (c['max_reference_images'] as num?)?.toInt() ?? d.maxReferenceImages,
      rgba: c['rgba'] as bool? ?? d.rgba,
      maxSide: (c['max_side'] as num?)?.toInt() ?? d.maxSide,
    );
  }

  static ImageDefaults _defaultsFromApi(Map<String, dynamic> j) {
    const d = ImageDefaults();
    final sizes = j['base_sizes'];
    final ratios = j['aspect_ratios'];
    return ImageDefaults(
      steps: (j['steps'] as num?)?.toInt() ?? d.steps,
      maxSteps: (j['max_steps'] as num?)?.toInt() ?? d.maxSteps,
      baseSize: (j['base_size'] as num?)?.toInt() ?? d.baseSize,
      baseSizes: sizes is List
          ? sizes.whereType<num>().map((n) => n.toInt()).toList()
          : d.baseSizes,
      aspectRatios: ratios is List
          ? ratios.whereType<String>().toList()
          : d.aspectRatios,
      guidance: (j['guidance'] as num?)?.toDouble() ?? d.guidance,
    );
  }

  /// The `generation` request object: only the fields the user
  /// overrode, in the server's snake_case names. `mode: auto` is the
  /// server default and is omitted like a `null`.
  Map<String, dynamic> imageOptionsToApi(ImageSettings s) => {
    if (s.mode != null && s.mode != ImageMode.auto) 'mode': s.mode!.name,
    if (s.baseSize != null) 'base_size': s.baseSize,
    if (s.aspectRatio != null) 'aspect_ratio': s.aspectRatio,
    if (s.steps != null) 'steps': s.steps,
    if (s.seed != null) 'seed': s.seed,
    if (s.guidance != null) 'guidance': s.guidance,
    if (s.negativePrompt != null && s.negativePrompt!.isNotEmpty)
      'negative_prompt': s.negativePrompt,
    if (s.transparent != null) 'transparent': s.transparent,
  };

  /// Tools in function-calling format — which tools the model may see is
  /// decided upstream (`enabledToolsOf`); the schema's local `$ref`s are
  /// inlined here, see [inlineLocalRefs].
  List<Map<String, dynamic>> toolsToApi(List<McpToolInfo> tools) => [
    for (final t in tools)
      {
        'type': 'function',
        'function': {
          'name': t.name,
          'description': t.description,
          'parameters': inlineLocalRefs(t.inputSchema),
        },
      },
  ];

  /// One message in wire format.
  ///
  /// Unresolved attachment ids (deleted, corrupted, not-yet-loaded) are
  /// silently dropped; the surrounding text/tool structure is preserved.
  /// Images ride on the message holding them: it is [buildMessages] that
  /// takes an assistant turn's off it, see [AssistantImagePlacement].
  Map<String, dynamic> messageToApi(Message message, ImageBytesMap imageBytes) {
    if (message.role == MessageRole.assistant) {
      final toolCalls = message.content
          .whereType<ToolCallContentBlock>()
          .toList();
      if (toolCalls.isNotEmpty) {
        final text = message.content
            .whereType<TextContentBlock>()
            .firstOrNull
            ?.text;
        return {
          'role': 'assistant',
          'content': text,
          'tool_calls': [
            for (final tc in toolCalls)
              {
                'id': tc.id,
                'type': 'function',
                'function': {
                  'name': tc.name,
                  'arguments': tc.arguments.trim().isEmpty
                      ? '{}'
                      : tc.arguments,
                },
              },
          ],
        };
      }
    }

    if (message.role == MessageRole.tool) {
      final result = message.content
          .whereType<ToolResultContentBlock>()
          .firstOrNull;
      if (result != null) {
        return {
          'role': 'tool',
          'tool_call_id': result.toolCallId,
          'content': result.resultContent
              .whereType<TextContentBlock>()
              .map((t) => t.text)
              .join('\n'),
        };
      }
    }

    final parts = contentParts(message, imageBytes);
    // Nothing left to say: an image-only turn whose images travel apart,
    // or a message whose only attachment no longer resolves. An empty
    // parts array is not a content value; the empty string is.
    if (parts.isEmpty) {
      return {'role': message.role.name, 'content': ''};
    }
    if (parts.length == 1 && parts.first['type'] == 'text') {
      return {'role': message.role.name, 'content': parts.first['text']};
    }
    return {'role': message.role.name, 'content': parts};
  }

  /// Content parts for a plain (non tool) message. Thinking, tool-call and
  /// tool-result blocks never go on the wire as parts.
  List<Map<String, dynamic>> contentParts(
    Message message,
    ImageBytesMap imageBytes,
  ) {
    final parts = <Map<String, dynamic>>[];
    for (final block in message.content) {
      switch (block) {
        case TextContentBlock(:final text):
          parts.add({'type': 'text', 'text': text});
        case ImageContentBlock(:final attachmentId):
          final loaded = imageBytes[attachmentId];
          if (loaded != null) parts.add(imageUrlPart(loaded));
        case ThinkingContentBlock():
        case ToolCallContentBlock():
        case ToolResultContentBlock():
          break;
      }
    }
    return parts;
  }

  Map<String, dynamic> imageUrlPart(ImageBytes image) => {
    'type': 'image_url',
    'image_url': {
      'url': 'data:${image.mimeType};base64,${base64Encode(image.bytes)}',
    },
  };

  /// Inverse of [imageUrlPart] for `data:<mime>;base64,<payload>` URLs.
  /// Returns `null` for anything else (http URLs, malformed base64), so
  /// callers can fall back to fetching or skipping. Decodes straight out of
  /// the URL string: a generated image is several MB of base64 and neither
  /// the payload nor the bytes are copied.
  static ImageBytes? decodeDataUrl(String url) {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    final header = url.substring(5, comma);
    if (!header.endsWith(';base64')) return null;
    final mime = header.substring(0, header.length - ';base64'.length);
    if (mime.isEmpty) return null;
    var end = url.length;
    while (end > comma + 1 && url.codeUnitAt(end - 1) <= 0x20) {
      end--;
    }
    try {
      return (
        bytes: base64.decoder.convert(url, comma + 1, end),
        mimeType: mime,
      );
    } on FormatException {
      return null;
    }
  }

  /// The images of a chat completion delta/message `images` array
  /// (OpenRouter convention: `[{type: image_url, image_url: {url}}]`), with
  /// what the server says it did (`generation.mode`): `true` for
  /// `text_to_image`, `false` for `reference_edit`, `null` when it says
  /// nothing. Entries without a URL are dropped.
  static List<({String url, bool? textToImage})> generatedImages(
    Object? images,
  ) {
    if (images is! List) return const [];
    final out = <({String url, bool? textToImage})>[];
    for (final entry in images) {
      if (entry is! Map) continue;
      final imageUrl = entry['image_url'];
      final url = imageUrl is Map ? imageUrl['url'] : entry['url'];
      if (url is! String || url.isEmpty) continue;
      final meta = entry['generation'] ?? entry['specterforge'];
      out.add((
        url: url,
        textToImage: switch (meta is Map ? meta['mode'] : null) {
          'text_to_image' => true,
          'reference_edit' => false,
          _ => null,
        },
      ));
    }
    return out;
  }

  /// [message] split into what stays on it and the image blocks that
  /// travel apart, in one pass — the two halves are defined once, so an
  /// image cannot be dropped from both or kept in both. With nothing to
  /// move the message itself comes back rather than a copy of it.
  ({Message message, List<ImageContentBlock> displaced}) _splitImageBlocks(
    Message message,
  ) {
    final kept = <ContentBlock>[];
    final images = <ImageContentBlock>[];
    for (final block in message.content) {
      if (block is ImageContentBlock) {
        images.add(block);
      } else {
        kept.add(block);
      }
    }
    return images.isEmpty
        ? (message: message, displaced: images)
        : (message: message.copyWith(content: kept), displaced: images);
  }

  /// Assistant turns whose tool calls cannot be replayed — arguments that
  /// never parsed, or a call left unanswered (the app was stopped or died
  /// between the call and its result) — plus the tool results that answer
  /// them. The server rejects a request holding either.
  Set<int> _indicesWithBrokenToolCalls(List<Message> history) {
    final skip = <int>{};
    for (var i = 0; i < history.length; i++) {
      final msg = history[i];
      if (msg.role != MessageRole.assistant) continue;
      final toolCalls = msg.content.whereType<ToolCallContentBlock>();
      if (toolCalls.isEmpty) continue;
      // The run of tool messages that answers this turn.
      final answered = <String>{};
      var j = i + 1;
      while (j < history.length && history[j].role == MessageRole.tool) {
        answered.addAll(
          history[j].content.whereType<ToolResultContentBlock>().map(
            (r) => r.toolCallId,
          ),
        );
        j++;
      }
      final usable = toolCalls.every(
        (tc) =>
            hasParseableToolCallArgs(tc.arguments) && answered.contains(tc.id),
      );
      if (usable) continue;
      for (var k = i; k < j; k++) {
        skip.add(k);
      }
    }
    return skip;
  }
}
