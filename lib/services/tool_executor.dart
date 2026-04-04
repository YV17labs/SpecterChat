import 'dart:convert';

import 'package:logging/logging.dart';

import '../database/i_conversation_repository.dart';
import '../models/app_settings.dart';
import '../models/message.dart';
import '../services/chat_logic.dart';
import '../services/i_mcp_service.dart';
import '../utils/id_gen.dart';

final _log = Logger('ToolExecutor');

/// Executes MCP tool calls and produces tool-result [Message]s.
///
/// Stateless — pass all dependencies per invocation.
class ToolExecutor {
  static const _prettyJson = JsonEncoder.withIndent('  ');

  const ToolExecutor();

  /// Execute all valid tool calls in parallel and persist results.
  ///
  /// Returns the list of tool-result messages saved to the repository.
  Future<List<Message>> executeAndSave({
    required String conversationId,
    required Map<int, ToolCallAccumulator> toolCalls,
    required IMcpService mcpService,
    required List<McpServerConfig> mcpServers,
    required IConversationRepository repo,
  }) async {
    final validCalls =
        toolCalls.entries.where((e) => e.value.isValid).toList();

    final futures = validCalls.map((entry) async {
      final tc = entry.value;
      final serverId = findServerForTool(mcpServers, tc.name!);

      if (serverId == null) {
        return _errorMessage(
          conversationId: conversationId,
          toolCallId: tc.id!,
          toolName: tc.name!,
          error: 'No connected MCP server provides tool "${tc.name}"',
        );
      }

      try {
        final argsStr = tc.argumentsBuffer.toString().trim();
        final arguments = argsStr.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(argsStr) as Map<String, dynamic>;
        final result =
            await mcpService.callTool(serverId, tc.name!, arguments);
        return _buildToolResultMessage(
          conversationId: conversationId,
          toolCallId: tc.id!,
          toolName: tc.name!,
          result: result,
        );
      } catch (e, st) {
        _log.warning('Tool execution failed: ${tc.name}', e, st);
        return _errorMessage(
          conversationId: conversationId,
          toolCallId: tc.id!,
          toolName: tc.name!,
          error: 'Error executing tool: $e',
        );
      }
    });

    final results = await Future.wait(futures);
    for (final msg in results) {
      await repo.saveMessage(msg);
    }
    return results;
  }

  Message _buildToolResultMessage({
    required String conversationId,
    required String toolCallId,
    required String toolName,
    required McpToolResult result,
  }) {
    final contentBlocks = <ContentBlock>[];
    final textParts = <String>[];
    String? imageBase64;
    String? imageMimeType;

    final rawItems = <Map<String, dynamic>>[];

    for (final content in result.content) {
      switch (content) {
        case McpTextContent(:final text):
          textParts.add(text);
          rawItems.add({'type': 'text', 'text': text});
        case McpImageContent(:final base64Data, :final mimeType):
          imageBase64 = base64Data;
          imageMimeType = mimeType;
          final sizeKb = (base64Data.length * 3 / 4 / 1024).round();
          rawItems.add({
            'type': 'image',
            'mimeType': mimeType,
            'data': '<base64 ~${sizeKb}KB>',
          });
      }
    }

    final rawResponse = _prettyJson.convert({
      'isError': result.isError,
      'content': rawItems,
    });

    contentBlocks.add(ContentBlock.toolResult(
      toolCallId: toolCallId,
      toolName: toolName,
      content: textParts.join('\n'),
      imageBase64: imageBase64,
      imageMimeType: imageMimeType,
      rawResponse: rawResponse,
    ));

    return Message(
      id: generateId(),
      conversationId: conversationId,
      role: MessageRole.tool,
      content: contentBlocks,
      createdAt: DateTime.now(),
    );
  }

  Message _errorMessage({
    required String conversationId,
    required String toolCallId,
    required String toolName,
    required String error,
  }) {
    return Message(
      id: generateId(),
      conversationId: conversationId,
      role: MessageRole.tool,
      content: [
        ContentBlock.toolResult(
          toolCallId: toolCallId,
          toolName: toolName,
          content: error,
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
