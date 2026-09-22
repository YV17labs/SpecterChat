import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/effective_settings.dart';
import '../../domain/models/message.dart';
import '../../domain/models/message_stats.dart';
import '../../domain/models/request_context.dart';
import '../../domain/repositories/i_attachment_repository.dart';
import '../../domain/repositories/i_conversation_repository.dart';
import '../../domain/repositories/i_message_repository.dart';
import '../../domain/services/i_file_saver.dart';
import '../../domain/services/llm_hook.dart' show correctionPrefix;
import 'conversation_runs.dart';

/// "Export": a conversation as one JSON file that a reader knowing nothing
/// of the app — a person or a model — can debug and improve from: every
/// message with all of its content (reasoning, tool calls, raw tool
/// results, images), what each request carried and was measured at, and
/// totals.
class ConversationExporter {
  ConversationExporter({
    required IConversationRepository conversations,
    required IMessageRepository messages,
    required IAttachmentRepository attachments,
    required IFileSaver files,
    Map<String, String> app = const {},
    DateTime Function() now = DateTime.now,
  }) : _conversations = conversations,
       _messages = messages,
       _attachments = attachments,
       _files = files,
       _app = app,
       _now = now;

  final IConversationRepository _conversations;
  final IMessageRepository _messages;
  final IAttachmentRepository _attachments;
  final IFileSaver _files;

  /// Who wrote the file (name, version…), copied into it.
  final Map<String, String> _app;
  final DateTime Function() _now;

  /// Asks where to save [conversationId]'s export, then builds and writes
  /// it — the history and its images are loaded only once a place was
  /// chosen. [settings]
  /// are the current global ones. `false` when the user cancelled or the
  /// conversation no longer exists.
  Future<bool> export(
    String conversationId, {
    required AppSettings settings,
  }) async {
    final conversation = await _conversations.getConversation(conversationId);
    if (conversation == null) return false;
    final now = _now();
    return _files.save(
      suggestedName: exportFileName(conversation.title, now),
      typeLabel: 'JSON',
      extension: 'json',
      mimeType: 'application/json',
      contents: () async {
        final messages = await _messages.getMessages(conversationId);
        final document = buildConversationExport(
          conversation: conversation,
          messages: messages,
          requestContexts: await _conversations.getRequestContexts(
            conversationId,
          ),
          images: await _attachments.loadMany({
            for (final m in messages) ...m.imageAttachmentIds(),
          }),
          settings: settings,
          exportedAt: now,
          app: _app,
        );
        // Straight to UTF-8, without the whole document as a String first.
        final bytes = JsonUtf8Encoder('  ').convert(document);
        return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      },
    );
  }
}

/// `<title> <yyyy-MM-dd HH.mm>.json`, the title stripped of what a file
/// name cannot hold.
String exportFileName(String title, DateTime at) {
  var name = title
      .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'[.\s]+$'), '');
  if (name.length > 80) name = name.substring(0, 80).trimRight();
  if (name.isEmpty) name = 'Conversation';
  return '$name ${DateFormat('yyyy-MM-dd HH.mm').format(at)}.json';
}

/// The export document of [conversation] and its [messages] (the whole
/// history, in order), with the [requestContexts] its turns reference and
/// the bytes of its [images]. Pure: all it says comes from the arguments.
///
/// What each turn was produced with is its own `stats`, recorded when it
/// was generated; `currentSettings` are today's, for reference. Never
/// written: the API key and MCP server headers, which may hold
/// credentials.
Map<String, dynamic> buildConversationExport({
  required Conversation conversation,
  required List<Message> messages,
  required AppSettings settings,
  required DateTime exportedAt,
  Map<String, RequestContext> requestContexts = const {},
  ImageBytesMap images = const {},
  Map<String, String> app = const {},
}) {
  final effective = EffectiveSettings.resolve(settings, conversation);
  return {
    'format': 'specterchat.conversation',
    'formatVersion': 1,
    'exportedAt': _time(exportedAt),
    'utcOffsetMinutes': exportedAt.timeZoneOffset.inMinutes,
    'app': app,
    'guide': _guide,
    // As stored, with the times in UTC.
    'conversation': {
      ...conversation.toJson(),
      'createdAt': _time(conversation.createdAt),
      'updatedAt': _time(conversation.updatedAt),
    },
    'currentSettings': {
      'baseUrl': settings.api.baseUrl,
      'selectedModel': settings.api.selectedModel,
      'contextLength': effective.contextLength,
      'systemPrompt': effective.systemPrompt,
      'generation': effective.generation.toJson(),
      'image': effective.image.toJson(),
      'mcpServers': [
        for (final server in settings.mcpServers)
          if (effective.enabledMcpServerIds.contains(server.id))
            {
              'id': server.id,
              'name': server.name,
              'url': server.url,
              'enabled': server.enabled,
            },
      ],
    },
    'requestContexts': {
      for (final MapEntry(:key, :value) in requestContexts.entries)
        key: value.toJson(),
    },
    'summary': _summary(messages),
    'runs': [for (final run in runsOf(messages)) _runJson(run)],
    'messages': [for (final message in messages) _message(message, images)],
  };
}

/// For a reader who knows nothing of the app: what the conversation is,
/// how it unfolded and what the model saw.
const _guide = {
  'purpose':
      'A complete record of one SpecterChat conversation, exported to '
      'debug and improve how models behave in it: everything the model '
      'received and produced, the tools it called and what they returned, '
      'and how long each step took.',
  'app':
      'SpecterChat is a desktop chat client for OpenAI-compatible '
      'chat/completions servers (Ollama, LM Studio, llama.cpp, mlx…). It '
      'gives the model tools from MCP servers — for example to see and '
      'drive a desktop: screenshots, clicks, key presses.',
  'loop':
      'The user sends a message. The app streams one request to the model '
      'with the whole history; the reply may hold reasoning (thinking), '
      'text and tool calls. The app runs every tool call on its MCP server, '
      'stores each result as a "tool" message, then sends the history '
      'again for the next reply — until a reply calls no tool. The '
      'assistant turns and tool results between two user messages form '
      'one run (see runs).',
  'request':
      'Each assistant turn records in stats what its request carried: the '
      'model, endpoint and sampling parameters (stats.generation), or the '
      'image options for an image model (stats.image); the system prompt '
      "as sent — the user's prompt followed by the MCP servers' "
      'instructions — and the tool definitions (name, description, input '
      'JSON schema) in requestContexts[stats.requestContextId]; and every '
      'earlier message of the conversation.',
  'whatTheModelSees':
      'Reasoning (thinking blocks) is never sent back. An assistant turn '
      'with tool calls is sent as its first text block and its tool_calls '
      '(the arguments exactly as the model wrote them). A tool result is '
      'sent as its text blocks only; its images follow in a user message '
      'placed after the run of tool results, each with the text "Image '
      'result from tool <name>." — tool messages cannot hold images. '
      'Images attached by the user or generated by an image model are sent '
      'as image parts of their message. An assistant turn whose tool-call '
      'arguments are not valid JSON is left out of later requests, with '
      'its tool results.',
  'autoCorrection':
      'A user message marked autoCorrection was not written by the user: '
      'the app sends it when the model wrote a tool call as text instead '
      'of calling it (a known Qwen 3.5/3.6 failure). The failed reply was '
      'discarded and is not in this file; the next reply has stats.retry '
      '> 0.',
  'blocks':
      "thinking: the model's reasoning. text: visible answer. toolCall: "
      'id, name, arguments (the raw JSON string the model wrote). '
      'toolResult: resultContent is what the model is sent, rawResponse '
      "the MCP server's whole answer (structuredContent, _meta… "
      'included). image: mimeType, byteSize, base64 (the bytes), aiOrigin '
      '(how a model made it, null for a photo, screenshot or tool '
      'result).',
  'measures':
      'stats is measured by the app when the message was produced and '
      'never recomputed; stats.server is what the model server reported, '
      'verbatim (usage, finish_reason, timings…). Tool results record the '
      'MCP call time and server. Messages written before stats existed '
      'only have completionTokens and durationMs.',
  'units':
      'Durations are milliseconds, times UTC. createdAt is stored to the '
      'second, stats.startedAt to the millisecond.',
  'derived':
      'Computed from stats: generationMs = durationMs - firstTokenMs, '
      'outputTokensPerSecond = completionTokens / generationMs, '
      'overallTokensPerSecond = completionTokens / durationMs.',
  'runs':
      'One per user message. generationMs is the sum the app shows as Σ '
      'under a reply; promptTokens adds up what each turn was sent, so a '
      'tool loop counts the context it resent every time; wallClockMs '
      'spans the first request to the end of the last measured message.',
  'images':
      'Image blocks carry their bytes as base64 (null when the attachment '
      'was deleted); a tool result rawResponse refers to them as '
      '"attachment:<attachmentId>", or, for results stored by earlier '
      'builds, as "<blob ~NKB>".',
  'privacy': 'The API key and MCP server headers are never exported.',
};

String _time(DateTime t) => t.toUtc().toIso8601String();

double? _round(double? value) =>
    value == null ? null : (value * 100).roundToDouble() / 100;

/// [message] as stored (`toJson`), with its blocks rewritten, its time in
/// UTC, and what follows from its stats.
Map<String, dynamic> _message(Message message, ImageBytesMap images) => {
  ...message.toJson(),
  'createdAt': _time(message.createdAt),
  if (message.role == MessageRole.user &&
      message.plainText.startsWith(correctionPrefix))
    'autoCorrection': true,
  'content': [for (final block in message.content) _block(block, images)],
  if (message.role == MessageRole.assistant) 'derived': _derived(message),
};

Map<String, dynamic> _derived(Message message) {
  final stats = message.generationStats;
  return {
    'timeToFirstTokenMs': stats?.firstTokenMs,
    'reasoningMs': stats?.reasoningMs,
    'generationMs': stats?.generationMs,
    'outputTokensPerSecond': _round(stats?.outputTokensPerSecond),
    'overallTokensPerSecond': _round(message.overallTokensPerSecond),
    'finishReason': stats?.finishReason,
  };
}

/// [block] as stored (`toJson`), with `runtimeType` named `type`: an
/// image with its bytes from [images] as base64, a tool result with its
/// inner blocks the same way and its raw response decoded.
Map<String, dynamic> _block(ContentBlock block, ImageBytesMap images) {
  final json = block.toJson();
  final type = json.remove('runtimeType');
  switch (block) {
    case ToolResultContentBlock(:final resultContent, :final rawResponse):
      json['resultContent'] = [
        for (final inner in resultContent) _block(inner, images),
      ];
      json['rawResponse'] = _jsonOrText(rawResponse);
    case ImageContentBlock(:final attachmentId):
      final bytes = images[attachmentId]?.bytes;
      json['base64'] = bytes == null ? null : base64Encode(bytes);
    case TextContentBlock() || ThinkingContentBlock() || ToolCallContentBlock():
      break;
  }
  return {'type': type, ...json};
}

/// [raw] decoded when it is JSON (a tool result's raw response is), as is
/// otherwise.
Object? _jsonOrText(String raw) {
  if (raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return raw;
  }
}

int _sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);

/// What [messages] cost: what the assistant turns weighed and how long
/// they took (`totalsOf`, the very sums the app shows as Σ under a
/// reply), and the time spent in tools.
Map<String, dynamic> _totals(Iterable<Message> messages) {
  final totals = totalsOf(messages);
  final tools = messages.where((m) => m.role == MessageRole.tool);
  return {
    'promptTokens': totals.promptTokens,
    'completionTokens': totals.completionTokens,
    'generationMs': totals.durationMs,
    'toolMs': _sum(tools.map((m) => m.durationMs)),
  };
}

int? _max(Iterable<int> values) =>
    values.isEmpty ? null : values.reduce(math.max);

Map<String, dynamic> _summary(List<Message> messages) {
  List<Message> withRole(MessageRole role) =>
      messages.where((m) => m.role == role).toList();
  final assistant = withRole(MessageRole.assistant);
  final tools = withRole(MessageRole.tool);
  final generations = assistant.map((m) => m.generationStats).nonNulls;
  final outcomes = <String, int>{};
  final byModel = <String, List<GenerationStats>>{};
  for (final g in generations) {
    outcomes.update(g.outcome.name, (n) => n + 1, ifAbsent: () => 1);
    (byModel[g.model] ??= []).add(g);
  }
  return {
    'messages': messages.length,
    'userMessages': withRole(MessageRole.user).length,
    'assistantTurns': assistant.length,
    'toolCalls': tools.length,
    ..._totals(messages),
    'maxPromptTokens': _max(generations.map((g) => g.promptTokens).nonNulls),
    'turnsWithStats': generations.length,
    'outcomes': outcomes,
    'models': {
      for (final MapEntry(:key, :value) in byModel.entries)
        key: _modelJson(value),
    },
  };
}

/// Totals of the turns one model generated. The decoding speed counts the
/// turns that measured both their tokens and their generation time.
Map<String, dynamic> _modelJson(List<GenerationStats> turns) {
  final timed = turns.where((g) => g.outputTokensPerSecond != null);
  final generationMs = _sum(timed.map((g) => g.generationMs!));
  final firstTokens = turns.map((g) => g.firstTokenMs).nonNulls;
  return {
    'turns': turns.length,
    'completionTokens': _sum(turns.map((g) => g.completionTokens ?? 0)),
    'durationMs': _sum(turns.map((g) => g.durationMs)),
    'outputTokensPerSecond': generationMs > 0
        ? _round(
            _sum(timed.map((g) => g.completionTokens!)) * 1000 / generationMs,
          )
        : null,
    'meanTimeToFirstTokenMs': firstTokens.isEmpty
        ? null
        : (_sum(firstTokens) / firstTokens.length).round(),
    'maxTimeToFirstTokenMs': _max(firstTokens),
  };
}

Map<String, dynamic> _runJson(ConversationRun run) {
  // Messages come in order, so the first measured one starts the run.
  final measured = run.answers.map((m) => m.stats).nonNulls.toList();
  return {
    'userMessageId': run.user?.id,
    'assistantTurns': run.answers
        .where((m) => m.role == MessageRole.assistant)
        .length,
    'toolCalls': run.answers.where((m) => m.role == MessageRole.tool).length,
    ..._totals(run.answers),
    'wallClockMs': measured.isEmpty
        ? null
        : measured.last.startedAt
              .add(Duration(milliseconds: measured.last.durationMs))
              .difference(measured.first.startedAt)
              .inMilliseconds,
  };
}
