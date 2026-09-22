import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/stream_accumulator.dart';
import 'package:specterchat/application/chat/tool_executor.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/message_stats.dart';
import 'package:specterchat/domain/services/i_mcp_service.dart';

import '../../support/fakes.dart';

ToolCallAccumulator _call(String id, String name, String args) {
  final tc = ToolCallAccumulator()
    ..id = id
    ..name = name;
  tc.argumentsBuffer.write(args);
  return tc;
}

void main() {
  const executor = ToolExecutor();
  late InMemoryMessageRepository messages;
  late InMemoryAttachmentRepository attachments;

  setUp(() {
    messages = InMemoryMessageRepository();
    attachments = InMemoryAttachmentRepository();
  });

  Future<List<Message>> run(
    List<ToolCallAccumulator> calls,
    FakeMcpService mcp,
  ) async {
    await executor.executeAndSave(
      conversationId: 'c',
      toolCalls: calls,
      mcpService: mcp,
      servers: [
        activeServer(tools: [tool('search'), tool('shot')]),
      ],
      messages: messages,
      attachments: attachments,
    );
    return messages.messagesFor('c');
  }

  test('text result becomes a tool message with raw response', () async {
    final mcp = FakeMcpService({
      'search': (args) =>
          McpToolResult(content: [McpTextContent('hit: ${args['q']}')]),
    });
    final saved = await run([_call('tc-1', 'search', '{"q":"dart"}')], mcp);

    expect(saved, hasLength(1));
    final block = saved.single.content.single as ToolResultContentBlock;
    expect(block.toolCallId, 'tc-1');
    expect(block.toolName, 'search');
    expect(block.resultContent, [const ContentBlock.text(text: 'hit: dart')]);
    expect(jsonDecode(block.rawResponse), {
      'isError': false,
      'content': [
        {'type': 'text', 'text': 'hit: dart'},
      ],
    });
  });

  test('image result is stored as an attachment referenced by id', () async {
    final bytes = [1, 2, 3, 4];
    final mcp = FakeMcpService({
      'shot': (_) => McpToolResult(
        content: [
          McpImageContent(
            base64Data: base64Encode(bytes),
            mimeType: 'image/png',
          ),
        ],
      ),
    });
    final saved = await run([_call('tc-1', 'shot', '')], mcp);

    final block = saved.single.content.single as ToolResultContentBlock;
    final image = block.resultContent.single as ImageContentBlock;
    expect(image.mimeType, 'image/png');
    expect(image.byteSize, 4);
    expect(attachments.rows[image.attachmentId]!.bytes, bytes);
    expect(block.rawResponse, isNot(contains(base64Encode(bytes))));
  });

  test('empty arguments are sent as an empty object', () async {
    final mcp = FakeMcpService({
      'search': (_) => McpToolResult(content: const []),
    });
    await run([_call('tc-1', 'search', '  ')], mcp);
    expect(mcp.calls.single.$3, isEmpty);
  });

  test('unknown tool yields an error result instead of throwing', () async {
    final saved = await run([_call('tc-1', 'nope', '{}')], FakeMcpService());
    final block = saved.single.content.single as ToolResultContentBlock;
    expect(
      (block.resultContent.single as TextContentBlock).text,
      contains('No connected MCP server provides tool "nope"'),
    );
    expect((jsonDecode(block.rawResponse) as Map)['isError'], isTrue);
  });

  test('a throwing tool yields an error result', () async {
    final mcp = FakeMcpService({'search': (_) => throw McpException('down')});
    final saved = await run([_call('tc-1', 'search', '{}')], mcp);
    final block = saved.single.content.single as ToolResultContentBlock;
    expect(
      (block.resultContent.single as TextContentBlock).text,
      contains('down'),
    );
  });

  test('unsupported content types are preserved as a placeholder', () async {
    final mcp = FakeMcpService({
      'search': (_) => McpToolResult(
        content: [
          McpUnsupportedContent(type: 'audio', raw: const {'type': 'audio'}),
        ],
      ),
    });
    final saved = await run([_call('tc-1', 'search', '{}')], mcp);
    final block = saved.single.content.single as ToolResultContentBlock;
    expect(
      (block.resultContent.single as TextContentBlock).text,
      '[Unsupported content type: audio]',
    );
  });

  test(
    'invalid accumulators are skipped, results are saved in order',
    () async {
      final mcp = FakeMcpService({
        'search': (args) =>
            McpToolResult(content: [McpTextContent('${args['n']}')]),
      });
      final saved = await run([
        _call('a', 'search', '{"n":1}'),
        ToolCallAccumulator()..id = 'nameless',
        _call('b', 'search', '{"n":2}'),
      ], mcp);
      expect(
        saved.map(
          (m) => (m.content.single as ToolResultContentBlock).toolCallId,
        ),
        ['a', 'b'],
      );
    },
  );

  test('each result records when its call started and who ran it', () async {
    await const ToolExecutor().executeAndSave(
      conversationId: 'c',
      toolCalls: [
        _call('tc-1', 'search', '{}'),
        _call('tc-2', 'nowhere', '{}'),
        _call('tc-3', 'shot', '{}'),
      ],
      mcpService: FakeMcpService({
        'search': (_) => McpToolResult(content: [McpTextContent('ok')]),
      }),
      servers: [
        activeServer(id: 'dg', tools: [tool('search'), tool('shot')]),
      ],
      messages: messages,
      attachments: attachments,
    );

    final saved = messages.messagesFor('c');
    final [found, missing, failed] = [
      for (final m in saved) m.stats! as ToolCallStats,
    ];
    expect((found.serverId, found.serverName), ('dg', 'dg'));
    expect(found.startedAt.isUtc, isTrue);
    expect((missing.serverId, missing.serverName), (null, null));
    // A call that throws is measured too.
    expect(failed.serverId, 'dg');
    expect(
      [for (final m in saved) m.durationMs],
      [
        for (final s in [found, missing, failed]) s.durationMs,
      ],
    );
  });

  test("the raw response is the server's whole answer, bytes aside", () async {
    final mcp = FakeMcpService({
      'shot': (_) => McpToolResult(
        content: [
          McpTextContent(
            'taken',
            raw: {
              'type': 'text',
              'text': 'taken',
              'annotations': {'priority': 1},
            },
          ),
          McpImageContent(
            base64Data: base64Encode([1, 2, 3]),
            mimeType: 'image/png',
            raw: {
              'type': 'image',
              'mimeType': 'image/png',
              '_meta': {'display': 1},
            },
          ),
        ],
        extra: {
          'structuredContent': {'width': 1920},
          '_meta': {'took': 12},
        },
      ),
    });
    final saved = await run([_call('tc-1', 'shot', '{}')], mcp);

    final block = saved.single.content.single as ToolResultContentBlock;
    final image = block.resultContent[1] as ImageContentBlock;
    expect(jsonDecode(block.rawResponse), {
      'isError': false,
      'content': [
        {
          'type': 'text',
          'text': 'taken',
          'annotations': {'priority': 1},
        },
        {
          'type': 'image',
          'mimeType': 'image/png',
          '_meta': {'display': 1},
          'data': 'attachment:${image.attachmentId}',
        },
      ],
      'structuredContent': {'width': 1920},
      '_meta': {'took': 12},
    });
  });
}
