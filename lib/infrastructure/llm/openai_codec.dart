import 'dart:convert';

import '../../domain/models/app_settings.dart';
import '../../domain/models/message.dart';
import 'schema_inliner.dart';

/// Translates domain messages and tools into the OpenAI chat/completions
/// wire format. The only place in the app that knows what an
/// `image_url` part or a `tool_calls` array looks like.
class OpenAiCodec {
  const OpenAiCodec();

  /// The messages array for one request.
  ///
  /// [imageBytes] carries preloaded bytes for every image attachment
  /// referenced by [history]. The base64 string is materialised here,
  /// handed to the HTTP client, and freed as soon as the body is
  /// serialised.
  List<Map<String, dynamic>> buildMessages({
    required List<Message> history,
    required String systemPrompt,
    ImageBytesMap imageBytes = const {},
  }) {
    final skip = _indicesWithBrokenToolCalls(history);
    final messages = <Map<String, dynamic>>[];

    if (systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }

    // Pending image content parts collected from consecutive tool results.
    // Flushed as a single user message once the tool-result run ends,
    // so we never break the required tool-message sequence (the spec
    // mandates all tool results appear consecutively after the assistant
    // tool_calls message).
    var pendingImageParts = <Map<String, dynamic>>[];

    for (var i = 0; i < history.length; i++) {
      if (skip.contains(i)) continue;
      final msg = history[i];
      messages.add(messageToApi(msg, imageBytes));

      // Collect images from tool results — the spec only allows text in
      // tool-role content, so images must go in a separate user message.
      if (msg.role == MessageRole.tool) {
        for (final block in msg.content) {
          if (block is! ToolResultContentBlock) continue;
          for (final inner in block.resultContent) {
            if (inner is! ImageContentBlock) continue;
            final loaded = imageBytes[inner.attachmentId];
            if (loaded == null) continue;
            pendingImageParts
              ..add(imageUrlPart(loaded))
              ..add({
                'type': 'text',
                'text': 'Image result from tool "${block.toolName}".',
              });
          }
        }
      }

      // Flush pending images when the consecutive tool-result run ends
      // (next message is not a tool, or we reached the end of history).
      if (pendingImageParts.isNotEmpty) {
        final nextIsNotTool =
            i + 1 >= history.length || history[i + 1].role != MessageRole.tool;
        if (nextIsNotTool) {
          messages.add({'role': 'user', 'content': pendingImageParts});
          pendingImageParts = <Map<String, dynamic>>[];
        }
      }
    }

    return messages;
  }

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

  /// Assistant turns whose tool-call arguments never parsed, plus the tool
  /// results that answer them. Replaying either makes the server reject
  /// the whole request.
  Set<int> _indicesWithBrokenToolCalls(List<Message> history) {
    final skip = <int>{};
    for (var i = 0; i < history.length; i++) {
      final msg = history[i];
      if (msg.role != MessageRole.assistant) continue;
      final toolCalls = msg.content.whereType<ToolCallContentBlock>();
      if (toolCalls.isEmpty) continue;
      if (toolCalls.every((tc) => hasParseableToolCallArgs(tc.arguments))) {
        continue;
      }
      skip.add(i);
      var j = i + 1;
      while (j < history.length && history[j].role == MessageRole.tool) {
        skip.add(j);
        j++;
      }
    }
    return skip;
  }
}
