import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/conversations/conversation_export.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/conversation_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/message_stats.dart';
import 'package:specterchat/domain/models/request_context.dart';
import 'package:specterchat/domain/services/llm_hook.dart';

import '../../support/fakes.dart';

void main() {
  late InMemoryConversationRepository conversations;
  late InMemoryMessageRepository messages;
  late InMemoryAttachmentRepository attachments;
  late FakeFileSaver files;
  late ConversationExporter exporter;
  late String convId;
  late String contextId;

  const settings = AppSettings(
    api: ApiSettings(
      baseUrl: 'http://localhost:11434/v1',
      apiKey: 'sk-secret',
      selectedModel: 'qwen3.8:27b-mlx',
      contextLength: 131072,
    ),
    mcpServers: [
      McpServerConfig(
        id: 'dg',
        name: 'DG - User',
        url: 'https://localhost:3000/mcp',
        headers: {'Authorization': 'Bearer mcp-secret'},
      ),
      McpServerConfig(id: 'other', name: 'Other', url: 'http://x'),
    ],
  );
  const context = RequestContext(
    systemPrompt: 'Be brief\n\n## MCP Server: DG - User\nUse the keyboard.',
    tools: [
      McpToolInfo(
        name: 'key_press',
        description: 'Press keys',
        inputSchema: {'type': 'object'},
      ),
    ],
  );
  final exportedAt = DateTime.utc(2026, 9, 22, 14, 35);
  final t0 = DateTime.utc(2026, 9, 22, 14);

  Message message(
    String id,
    MessageRole role,
    List<ContentBlock> content, {
    MessageStats? stats,
    int? completionTokens,
    int? durationMs,
  }) => testMessage(
    role,
    content,
    id: id,
    conversationId: convId,
    createdAt: t0,
    stats: stats,
    completionTokens: completionTokens,
    durationMs: durationMs,
  );

  setUp(() async {
    conversations = InMemoryConversationRepository();
    messages = InMemoryMessageRepository();
    attachments = InMemoryAttachmentRepository();
    files = FakeFileSaver();
    exporter = ConversationExporter(
      conversations: conversations,
      messages: messages,
      attachments: attachments,
      files: files,
      app: const {'name': 'SpecterChat', 'version': '0.7.3 (build 1)'},
      now: () => exportedAt,
    );
    convId = await conversations.createConversation(
      settings: const ConversationSettings(
        generation: GenerationSettings(temperature: 0.6, topK: 20),
        enabledMcpServerIds: ['dg'],
      ),
    );
    await conversations.renameConversation(convId, 'Hacker News: page…');

    contextId = await conversations.saveRequestContext(convId, context);
    await attachments.storeBytes(
      attachmentId: 'shot-1',
      messageId: 'm3',
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
    );
    final first = testGenerationStats(
      startedAt: t0,
    ).copyWith(requestContextId: contextId);
    final tool = ToolCallStats(
      startedAt: t0.add(const Duration(milliseconds: 15800)),
      durationMs: 1200,
      serverId: 'dg',
      serverName: 'DG - User',
    );
    final second = testGenerationStats(
      startedAt: t0.add(const Duration(seconds: 17)),
      durationMs: 5000,
      firstTokenMs: 1000,
      firstAnswerMs: 1000,
      completionTokens: 82,
    );
    for (final m in [
      message('m1', MessageRole.user, [
        const ContentBlock.text(text: 'Open Hacker News'),
      ]),
      message('m2', MessageRole.assistant, [
        const ContentBlock.thinking(text: 'The user wants…'),
        const ContentBlock.text(text: 'Opening it.'),
        const ContentBlock.toolCall(
          id: 'tc-1',
          name: 'key_press',
          arguments: '{"keys": "ctrl+l"}',
        ),
      ], stats: first),
      message('m3', MessageRole.tool, [
        ContentBlock.toolResult(
          toolCallId: 'tc-1',
          toolName: 'key_press',
          resultContent: const [
            ContentBlock.text(text: 'ok'),
            ContentBlock.image(
              attachmentId: 'shot-1',
              mimeType: 'image/png',
              byteSize: 3,
            ),
            ContentBlock.image(
              attachmentId: 'deleted',
              mimeType: 'image/png',
              byteSize: 9,
            ),
          ],
          rawResponse: jsonEncode({'isError': false}),
        ),
      ], stats: tool),
      message('m4', MessageRole.assistant, [
        const ContentBlock.text(text: 'Done.'),
      ], stats: second),
      // Written before stats existed.
      message('m5', MessageRole.user, [const ContentBlock.text(text: 'Old')]),
      message(
        'm6',
        MessageRole.assistant,
        [const ContentBlock.text(text: 'Legacy')],
        completionTokens: 100,
        durationMs: 4000,
      ),
    ]) {
      await messages.saveMessage(m);
    }
  });

  Future<Map<String, dynamic>> exported() async {
    expect(await exporter.export(convId, settings: settings), isTrue);
    return jsonDecode(utf8.decode(files.saved.single.bytes))
        as Map<String, dynamic>;
  }

  test('every message with its content, stats and derived values', () async {
    final doc = await exported();
    expect(doc['format'], 'specterchat.conversation');
    expect(doc['exportedAt'], '2026-09-22T14:35:00.000Z');
    expect(doc['app'], {'name': 'SpecterChat', 'version': '0.7.3 (build 1)'});

    final list = (doc['messages'] as List).cast<Map<String, dynamic>>();
    expect(list.map((m) => m['id']), ['m1', 'm2', 'm3', 'm4', 'm5', 'm6']);

    final reply = list[1];
    expect(reply['content'], [
      {'type': 'thinking', 'text': 'The user wants…'},
      {'type': 'text', 'text': 'Opening it.'},
      {
        'type': 'toolCall',
        'id': 'tc-1',
        'name': 'key_press',
        'arguments': '{"keys": "ctrl+l"}',
      },
    ]);
    expect(
      reply['stats'],
      jsonDecode(
        jsonEncode(
          testGenerationStats(
            startedAt: t0,
          ).copyWith(requestContextId: contextId),
        ),
      ),
    );
    expect(doc['requestContexts'], {
      contextId: jsonDecode(jsonEncode(context)),
    });
    expect(reply['derived'], {
      'timeToFirstTokenMs': 1700,
      'reasoningMs': 7300,
      'generationMs': 14000,
      'outputTokensPerSecond': 25.29,
      'overallTokensPerSecond': 22.55,
      'finishReason': 'tool_calls',
    });

    final result = list[2];
    expect(result['content'], [
      {
        'type': 'toolResult',
        'toolCallId': 'tc-1',
        'toolName': 'key_press',
        'resultContent': [
          {'type': 'text', 'text': 'ok'},
          {
            'type': 'image',
            'attachmentId': 'shot-1',
            'mimeType': 'image/png',
            'byteSize': 3,
            'photoMetadata': null,
            'aiOrigin': null,
            'base64': 'AQID',
          },
          {
            'type': 'image',
            'attachmentId': 'deleted',
            'mimeType': 'image/png',
            'byteSize': 9,
            'photoMetadata': null,
            'aiOrigin': null,
            'base64': null,
          },
        ],
        'rawResponse': {'isError': false},
      },
    ]);
    expect((result['stats'] as Map)['serverName'], 'DG - User');
    expect(result['durationMs'], 1200);

    // Legacy reply: only what its columns hold.
    expect(list[5]['stats'], isNull);
    expect((list[5]['derived'] as Map)['overallTokensPerSecond'], 25.0);
    expect((list[5]['derived'] as Map)['outputTokensPerSecond'], isNull);
  });

  test('summary per model and one run per user message', () async {
    final doc = await exported();
    final summary = doc['summary'] as Map<String, dynamic>;
    expect(summary['assistantTurns'], 3);
    expect(summary['toolCalls'], 1);
    expect(summary['completionTokens'], 536);
    // Both measured turns were sent the same context, and both count.
    expect(summary['promptTokens'], 50368);
    expect(summary['maxPromptTokens'], 25184);
    expect(summary['generationMs'], 24700);
    expect(summary['toolMs'], 1200);
    expect(summary['turnsWithStats'], 2);
    expect(summary['outcomes'], {'completed': 2});
    expect(summary['models'], {
      'qwen3.8:27b-mlx': {
        'turns': 2,
        'completionTokens': 436,
        'durationMs': 20700,
        // (354 + 82) tokens over (14000 + 4000) ms.
        'outputTokensPerSecond': 24.22,
        'meanTimeToFirstTokenMs': 1350,
        'maxTimeToFirstTokenMs': 1700,
      },
    });

    expect(doc['runs'], [
      {
        'userMessageId': 'm1',
        'assistantTurns': 2,
        'toolCalls': 1,
        // The tool round resent the context, so it is counted twice —
        // what the run cost, the same Σ the reply shows.
        'promptTokens': 50368,
        'completionTokens': 436,
        'generationMs': 20700,
        'toolMs': 1200,
        // First request at t0, second reply ends at t0 + 17s + 5s.
        'wallClockMs': 22000,
      },
      {
        'userMessageId': 'm5',
        'assistantTurns': 1,
        'toolCalls': 0,
        // A reply written before stats existed reports no usage.
        'promptTokens': 0,
        'completionTokens': 100,
        'generationMs': 4000,
        'toolMs': 0,
        'wallClockMs': null,
      },
    ]);
  });

  test('current settings without the API key nor MCP headers', () async {
    final doc = await exported();
    final current = doc['currentSettings'] as Map<String, dynamic>;
    expect(current['baseUrl'], 'http://localhost:11434/v1');
    expect(current['selectedModel'], 'qwen3.8:27b-mlx');
    expect((current['generation'] as Map)['topK'], 20);
    expect(current['mcpServers'], [
      {
        'id': 'dg',
        'name': 'DG - User',
        'url': 'https://localhost:3000/mcp',
        'enabled': true,
      },
    ]);
    final text = utf8.decode(files.saved.single.bytes);
    expect(text, isNot(contains('sk-secret')));
    expect(text, isNot(contains('mcp-secret')));
  });

  test('a cancelled dialog writes nothing', () async {
    files.cancel = true;
    expect(await exporter.export(convId, settings: settings), isFalse);
    expect(files.saved, isEmpty);
  });

  test('a deleted conversation is not exported', () async {
    expect(await exporter.export('gone', settings: settings), isFalse);
    expect(files.saved, isEmpty);
  });

  test('a guide for a reader without context; auto-corrections flagged', () {
    final doc = buildConversationExport(
      conversation: conversations.rows[convId]!,
      messages: [
        message('u', MessageRole.user, [const ContentBlock.text(text: 'Go')]),
        message('c', MessageRole.user, [
          const ContentBlock.text(text: '$correctionPrefix and was discarded.'),
        ]),
      ],
      settings: settings,
      exportedAt: exportedAt,
    );
    expect(
      (doc['guide'] as Map).keys,
      containsAll(['purpose', 'loop', 'request', 'whatTheModelSees']),
    );
    final [user, correction] = (doc['messages'] as List)
        .cast<Map<String, dynamic>>();
    expect(user.containsKey('autoCorrection'), isFalse);
    expect(correction['autoCorrection'], isTrue);
  });

  test('file name: the title made safe, then the date', () {
    final at = DateTime(2026, 9, 22, 9, 5);
    expect(
      exportFileName("Hacker News: page d'accueil....", at),
      "Hacker News page d'accueil 2026-09-22 09.05.json",
    );
    expect(exportFileName(' / ', at), 'Conversation 2026-09-22 09.05.json');
    expect(exportFileName('x' * 200, at), '${'x' * 80} 2026-09-22 09.05.json');
  });
}
