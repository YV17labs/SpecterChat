import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../core/id_gen.dart';
import '../../domain/models/message.dart';
import '../../domain/repositories/i_attachment_repository.dart';
import '../../domain/repositories/i_message_repository.dart';
import '../../domain/services/i_mcp_service.dart';
import '../mcp/active_mcp_server.dart';
import 'stream_accumulator.dart';

final _log = Logger('ToolExecutor');

/// Executes MCP tool calls and produces tool-result [Message]s.
///
/// Stateless — pass all dependencies per invocation. Images in tool
/// results are extracted into the attachments table as blobs; the
/// resulting [ImageContentBlock] references them by id only so
/// `Message.content` JSON stays small.
class ToolExecutor {
  static const _prettyJson = JsonEncoder.withIndent('  ');

  const ToolExecutor();

  /// Execute all valid tool calls in parallel and persist results.
  Future<void> executeAndSave({
    required String conversationId,
    required Map<int, ToolCallAccumulator> toolCalls,
    required IMcpService mcpService,
    required List<ActiveMcpServer> servers,
    required IMessageRepository messages,
    required IAttachmentRepository attachments,
  }) async {
    final validCalls = toolCalls.values.where((tc) => tc.isValid).toList();

    final prepared = await Future.wait(
      validCalls.map(
        (call) => _prepareSingle(
          call: call,
          conversationId: conversationId,
          mcpService: mcpService,
          servers: servers,
        ),
      ),
    );

    // Atomic write — without it, the `messages` watcher emits between
    // the message and attachment inserts and the UI gets stuck on
    // "Image unavailable" for an attachmentId whose row hasn't landed.
    await messages.runInTransaction(() async {
      for (final p in prepared) {
        await messages.saveMessage(p.message);
        for (final pending in p.pendingAttachments) {
          await attachments.storeBytes(
            attachmentId: pending.attachmentId,
            messageId: p.message.id,
            bytes: pending.bytes,
            mimeType: pending.mimeType,
          );
        }
      }
    });
  }

  Future<_PreparedToolResult> _prepareSingle({
    required ToolCallAccumulator call,
    required String conversationId,
    required IMcpService mcpService,
    required List<ActiveMcpServer> servers,
  }) async {
    final messageId = generateId();
    final toolName = call.name!;
    final toolCallId = call.id!;
    final serverId = findServerForTool(servers, toolName);

    if (serverId == null) {
      return _PreparedToolResult(
        message: _errorMessage(
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
      return _PreparedToolResult(
        message: _errorMessage(
          messageId: messageId,
          conversationId: conversationId,
          toolCallId: toolCallId,
          toolName: toolName,
          error: 'Error executing tool: $e',
        ),
      );
    }
  }

  _PreparedToolResult _buildFromResult({
    required String messageId,
    required String conversationId,
    required String toolCallId,
    required String toolName,
    required McpToolResult result,
  }) {
    final resultContent = <ContentBlock>[];
    final rawItems = <Map<String, dynamic>>[];
    final pending = <_PendingAttachment>[];

    for (final content in result.content) {
      switch (content) {
        case McpTextContent(:final text):
          resultContent.add(ContentBlock.text(text: text));
          rawItems.add({'type': 'text', 'text': text});
        case McpImageContent(:final base64Data, :final mimeType):
          final attachmentId = generateId();
          final bytes = base64Decode(base64Data);
          pending.add(
            _PendingAttachment(
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
          rawItems.add({
            'type': 'image',
            'mimeType': mimeType,
            'data': '<blob ~${(bytes.length / 1024).round()}KB>',
          });
        case McpUnsupportedContent(:final type, :final raw):
          resultContent.add(
            ContentBlock.text(text: '[Unsupported content type: $type]'),
          );
          rawItems.add(raw);
      }
    }

    final rawResponse = _prettyJson.convert({
      'isError': result.isError,
      'content': rawItems,
    });

    return _PreparedToolResult(
      message: Message(
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
      pendingAttachments: pending,
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

class _PreparedToolResult {
  final Message message;
  final List<_PendingAttachment> pendingAttachments;
  const _PreparedToolResult({
    required this.message,
    this.pendingAttachments = const [],
  });
}

class _PendingAttachment {
  final String attachmentId;
  final Uint8List bytes;
  final String mimeType;
  const _PendingAttachment({
    required this.attachmentId,
    required this.bytes,
    required this.mimeType,
  });
}
