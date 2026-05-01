import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../database/i_attachment_repository.dart';
import '../database/i_conversation_repository.dart';
import '../models/app_settings.dart';
import '../models/message.dart';
import '../services/chat_logic.dart';
import '../services/i_mcp_service.dart';
import '../utils/id_gen.dart';

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
    required List<McpServerConfig> mcpServers,
    required IConversationRepository repo,
    required IAttachmentRepository attachments,
  }) async {
    final validCalls =
        toolCalls.entries.where((e) => e.value.isValid).toList();

    final prepared =
        await Future.wait(validCalls.map((entry) => _prepareSingle(
              call: entry.value,
              conversationId: conversationId,
              mcpService: mcpService,
              mcpServers: mcpServers,
            )));

    // Atomic write — without it, the `messages` watcher emits between
    // the message and attachment inserts and the UI gets stuck on
    // "Image unavailable" for an attachmentId whose row hasn't landed.
    await repo.runInTransaction(() async {
      for (final p in prepared) {
        await repo.saveMessage(p.message);
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
    required List<McpServerConfig> mcpServers,
  }) async {
    final messageId = generateId();
    final serverId = findServerForTool(mcpServers, call.name!);

    if (serverId == null) {
      return _PreparedToolResult(
        message: _errorMessage(
          messageId: messageId,
          conversationId: conversationId,
          toolCallId: call.id!,
          toolName: call.name!,
          error: 'No connected MCP server provides tool "${call.name}"',
        ),
        pendingAttachments: const [],
      );
    }

    try {
      final argsStr = call.argumentsBuffer.toString().trim();
      final arguments = argsStr.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(argsStr) as Map<String, dynamic>;
      final result = await mcpService.callTool(serverId, call.name!, arguments);
      return _buildFromResult(
        messageId: messageId,
        conversationId: conversationId,
        toolCallId: call.id!,
        toolName: call.name!,
        result: result,
      );
    } catch (e, st) {
      _log.warning('Tool execution failed: ${call.name}', e, st);
      return _PreparedToolResult(
        message: _errorMessage(
          messageId: messageId,
          conversationId: conversationId,
          toolCallId: call.id!,
          toolName: call.name!,
          error: 'Error executing tool: $e',
        ),
        pendingAttachments: const [],
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
          pending.add(_PendingAttachment(
            attachmentId: attachmentId,
            bytes: bytes,
            mimeType: mimeType,
          ));
          resultContent.add(ContentBlock.image(
            attachmentId: attachmentId,
            mimeType: mimeType,
            byteSize: bytes.length,
          ));
          rawItems.add({
            'type': 'image',
            'mimeType': mimeType,
            'data': '<blob ~${(bytes.length / 1024).round()}KB>',
          });
        case McpUnsupportedContent(:final type, :final raw):
          resultContent.add(ContentBlock.text(
            text: '[Unsupported content type: $type]',
          ));
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
          rawResponse: _prettyJson.convert({
            'isError': true,
            'error': error,
          }),
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
    required this.pendingAttachments,
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
