import 'dart:convert';

import 'package:logging/logging.dart';

import '../../core/id_gen.dart';
import '../../domain/models/message.dart';
import '../../domain/models/message_stats.dart';
import '../../domain/repositories/i_attachment_repository.dart';
import '../../domain/repositories/i_message_repository.dart';
import '../../domain/services/i_mcp_service.dart';
import '../mcp/active_mcp_server.dart';
import 'message_writes.dart';
import 'stream_accumulator.dart';

final _log = Logger('ToolExecutor');

/// Executes MCP tool calls and produces tool-result [Message]s.
///
/// Stateless — pass all dependencies per invocation. Images in tool
/// results are extracted into the attachments table as blobs; the
/// resulting [ImageContentBlock] references them by id only so
/// `Message.content` JSON stays small. Each result records how long its
/// call took and which server ran it ([ToolCallStats]).
class ToolExecutor {
  static const _prettyJson = JsonEncoder.withIndent('  ');

  const ToolExecutor();

  /// Execute all valid tool calls in parallel. Each result is written as
  /// soon as its call returns, so a crash while a slower one still runs
  /// keeps those already done; ids are minted when the calls start, so the
  /// results still read in call order.
  Future<void> executeAndSave({
    required String conversationId,
    required List<ToolCallAccumulator> toolCalls,
    required IMcpService mcpService,
    required List<ActiveMcpServer> servers,
    required IMessageRepository messages,
    required IAttachmentRepository attachments,
  }) async {
    await Future.wait(
      toolCalls
          .where((tc) => tc.isValid)
          .map(
            (call) async => saveMessagesWithAttachments(messages, attachments, [
              await _prepareSingle(
                call: call,
                conversationId: conversationId,
                mcpService: mcpService,
                servers: servers,
              ),
            ]),
          ),
    );
  }

  /// [_call], timed: the result records when the call started, how long
  /// it took and which server ran it.
  Future<MessageWrite> _prepareSingle({
    required ToolCallAccumulator call,
    required String conversationId,
    required IMcpService mcpService,
    required List<ActiveMcpServer> servers,
  }) async {
    final serverId = findServerForTool(servers, call.name!);
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    final write = await _call(
      call: call,
      serverId: serverId,
      conversationId: conversationId,
      mcpService: mcpService,
    );
    final stats = ToolCallStats(
      startedAt: startedAt,
      durationMs: stopwatch.elapsedMilliseconds,
      serverId: serverId,
      serverName: servers.where((s) => s.id == serverId).firstOrNull?.name,
    );
    return MessageWrite(
      write.message.copyWith(durationMs: stats.durationMs, stats: stats),
      attachments: write.attachments,
    );
  }

  Future<MessageWrite> _call({
    required ToolCallAccumulator call,
    required String? serverId,
    required String conversationId,
    required IMcpService mcpService,
  }) async {
    final messageId = generateId();
    final toolName = call.name!;
    final toolCallId = call.callId;

    if (serverId == null) {
      return MessageWrite(
        _errorMessage(
          messageId: messageId,
          conversationId: conversationId,
          toolCallId: toolCallId,
          toolName: toolName,
          error: 'No connected MCP server provides tool "$toolName"',
        ),
      );
    }

    try {
      final argsStr = call.arguments.trim();
      final arguments = argsStr.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(argsStr) as Map<String, dynamic>;
      final result = await mcpService.callTool(serverId, toolName, arguments);
      return _buildFromResult(
        messageId: messageId,
        conversationId: conversationId,
        toolCallId: toolCallId,
        toolName: toolName,
        result: result,
      );
    } catch (e, st) {
      _log.warning('Tool execution failed: $toolName', e, st);
      return MessageWrite(
        _errorMessage(
          messageId: messageId,
          conversationId: conversationId,
          toolCallId: toolCallId,
          toolName: toolName,
          error: 'Error executing tool: $e',
        ),
      );
    }
  }

  MessageWrite _buildFromResult({
    required String messageId,
    required String conversationId,
    required String toolCallId,
    required String toolName,
    required McpToolResult result,
  }) {
    final resultContent = <ContentBlock>[];
    final rawItems = <Map<String, dynamic>>[];
    final pending = <PendingAttachment>[];

    for (final content in result.content) {
      switch (content) {
        case McpTextContent(:final text, :final raw):
          resultContent.add(ContentBlock.text(text: text));
          rawItems.add(raw ?? {'type': 'text', 'text': text});
        case McpImageContent(:final base64Data, :final mimeType, :final raw):
          final attachmentId = generateId();
          final bytes = base64Decode(base64Data);
          pending.add(
            PendingAttachment(
              attachmentId: attachmentId,
              bytes: bytes,
              mimeType: mimeType,
            ),
          );
          resultContent.add(
            ContentBlock.image(
              attachmentId: attachmentId,
              mimeType: mimeType,
              byteSize: bytes.length,
            ),
          );
          // The bytes are the attachment's; the item keeps the rest.
          rawItems.add({
            ...?raw,
            'type': 'image',
            'mimeType': mimeType,
            'data': 'attachment:$attachmentId',
          });
        case McpUnsupportedContent(:final type, :final raw):
          resultContent.add(
            ContentBlock.text(text: '[Unsupported content type: $type]'),
          );
          rawItems.add(raw);
      }
    }

    // The server's whole answer, verbatim but for image bytes.
    final rawResponse = _prettyJson.convert({
      'isError': result.isError,
      'content': rawItems,
      ...result.extra,
    });

    return MessageWrite(
      Message(
        id: messageId,
        conversationId: conversationId,
        role: MessageRole.tool,
        content: [
          ContentBlock.toolResult(
            toolCallId: toolCallId,
            toolName: toolName,
            resultContent: resultContent,
            rawResponse: rawResponse,
          ),
        ],
        createdAt: DateTime.now(),
      ),
      attachments: pending,
    );
  }

  Message _errorMessage({
    required String messageId,
    required String conversationId,
    required String toolCallId,
    required String toolName,
    required String error,
  }) {
    return Message(
      id: messageId,
      conversationId: conversationId,
      role: MessageRole.tool,
      content: [
        ContentBlock.toolResult(
          toolCallId: toolCallId,
          toolName: toolName,
          resultContent: [ContentBlock.text(text: error)],
          rawResponse: _prettyJson.convert({'isError': true, 'error': error}),
        ),
      ],
      createdAt: DateTime.now(),
    );
  }
}
