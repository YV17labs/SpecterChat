import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_settings.dart';
import '../models/message.dart';
import '../services/llm_service.dart';
import '../services/mcp_service.dart';
import '../utils/id_gen.dart';
import 'conversation_provider.dart';
import 'llm_provider.dart';
import 'mcp_provider.dart';
import 'settings_provider.dart';

/// Holds the current streaming state for the active chat.
class ChatState {
  final List<Message> streamingMessages;
  final bool isGenerating;
  final String? error;

  const ChatState({
    this.streamingMessages = const [],
    this.isGenerating = false,
    this.error,
  });

  ChatState copyWith({
    List<Message>? streamingMessages,
    bool? isGenerating,
    String? error,
  }) {
    return ChatState(
      streamingMessages: streamingMessages ?? this.streamingMessages,
      isGenerating: isGenerating ?? this.isGenerating,
      error: error,
    );
  }
}

final chatProvider =
    StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(ref);
});

class ChatNotifier extends StateNotifier<ChatState> {
  final Ref _ref;
  CancelToken? _cancelToken;

  ChatNotifier(this._ref) : super(const ChatState());

  /// Send a user message and stream the assistant's response.
  Future<void> sendMessage(
      String conversationId, String userText) async {
    if (state.isGenerating) return;

    final actions = _ref.read(conversationActionsProvider);
    final llm = _ref.read(llmServiceProvider);
    final settings = _ref.read(settingsProvider);
    final mcpService = _ref.read(mcpServiceProvider);
    final mcpTools = _ref.read(mcpToolsProvider);

    // Create and save user message
    final userMessage = Message(
      id: generateId(),
      conversationId: conversationId,
      role: MessageRole.user,
      content: [ContentBlock.text(text: userText)],
      createdAt: DateTime.now(),
    );
    await actions.saveMessage(userMessage);

    // Build messages array for API
    final conversation =
        _ref.read(selectedConversationProvider);
    final historyAsync =
        _ref.read(conversationMessagesProvider(conversationId));
    final history = historyAsync.valueOrNull ?? [];

    final apiMessages = _buildApiMessages(
      history: [...history, userMessage],
      systemPrompt:
          conversation?.systemPrompt ?? settings.defaultSystemPrompt,
    );

    _cancelToken = CancelToken();
    state = state.copyWith(isGenerating: true, error: null);

    await _streamResponse(
      conversationId: conversationId,
      apiMessages: apiMessages,
      llm: llm,
      mcpTools: mcpTools,
      mcpService: mcpService,
      settings: settings,
      actions: actions,
    );
  }

  Future<void> _streamResponse({
    required String conversationId,
    required List<Map<String, dynamic>> apiMessages,
    required LlmService llm,
    required List<Map<String, dynamic>> mcpTools,
    required McpService mcpService,
    required AppSettings settings,
    required ConversationActions actions,
  }) async {
    final contentBuffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    final toolCalls = <int, _ToolCallAccumulator>{};

    final assistantId = generateId();

    await for (final event in llm.streamChatCompletion(
      messages: apiMessages,
      tools: mcpTools.isNotEmpty ? mcpTools : null,
      cancelToken: _cancelToken,
    )) {
      if (!mounted) return;

      switch (event) {
        case ContentDelta(:final text):
          contentBuffer.write(text);
          _updateStreamingMessage(
            assistantId,
            conversationId,
            contentBuffer.toString(),
            thinkingBuffer.toString(),
            toolCalls,
          );

        case ThinkingDelta(:final text):
          thinkingBuffer.write(text);
          _updateStreamingMessage(
            assistantId,
            conversationId,
            contentBuffer.toString(),
            thinkingBuffer.toString(),
            toolCalls,
          );

        case ToolCallDelta(
            :final index,
            :final id,
            :final name,
            :final argumentsDelta
          ):
          toolCalls.putIfAbsent(
              index, () => _ToolCallAccumulator());
          final tc = toolCalls[index]!;
          if (id != null) tc.id = id;
          if (name != null) tc.name = name;
          tc.argumentsBuffer.write(argumentsDelta);
          _updateStreamingMessage(
            assistantId,
            conversationId,
            contentBuffer.toString(),
            thinkingBuffer.toString(),
            toolCalls,
          );

        case StreamDone():
          // Finalize and save the assistant message
          final assistantMessage = _buildAssistantMessage(
            assistantId,
            conversationId,
            contentBuffer.toString(),
            thinkingBuffer.toString(),
            toolCalls,
            isStreaming: false,
          );
          await actions.saveMessage(assistantMessage);
          state = state.copyWith(streamingMessages: []);

          // If there are tool calls, execute them
          if (toolCalls.isNotEmpty) {
            await _handleToolCalls(
              conversationId: conversationId,
              toolCalls: toolCalls,
              mcpService: mcpService,
              settings: settings,
              llm: llm,
              mcpTools: mcpTools,
              actions: actions,
            );
          } else {
            state = state.copyWith(isGenerating: false);

            // Auto-title if this is the first exchange
            _autoTitleIfNeeded(conversationId, contentBuffer.toString(),
                actions);
          }

        case StreamError(:final message):
          state = state.copyWith(
            isGenerating: false,
            error: message,
            streamingMessages: [],
          );
      }
    }
  }

  Future<void> _handleToolCalls({
    required String conversationId,
    required Map<int, _ToolCallAccumulator> toolCalls,
    required McpService mcpService,
    required AppSettings settings,
    required LlmService llm,
    required List<Map<String, dynamic>> mcpTools,
    required ConversationActions actions,
  }) async {
    // Execute tool calls in parallel, then save results in order
    final validCalls = toolCalls.entries
        .where((e) => e.value.id != null && e.value.name != null)
        .toList();

    final futures = validCalls.map((entry) async {
      final tc = entry.value;
      final serverId =
          findServerForTool(settings.mcpServers, tc.name!);

      if (serverId == null) {
        return Message(
          id: generateId(),
          conversationId: conversationId,
          role: MessageRole.tool,
          content: [
            ContentBlock.toolResult(
              toolCallId: tc.id!,
              toolName: tc.name!,
              content:
                  'Error: No connected MCP server provides tool "${tc.name}"',
            ),
          ],
          createdAt: DateTime.now(),
        );
      }

      try {
        final arguments = jsonDecode(tc.argumentsBuffer.toString())
            as Map<String, dynamic>;
        final result =
            await mcpService.callTool(serverId, tc.name!, arguments);

        final contentBlocks = <ContentBlock>[];
        final textParts = <String>[];
        String? imageBase64;
        String? imageMimeType;

        for (final content in result.content) {
          switch (content) {
            case McpTextContent(:final text):
              textParts.add(text);
            case McpImageContent(:final base64Data, :final mimeType):
              imageBase64 = base64Data;
              imageMimeType = mimeType;
          }
        }

        contentBlocks.add(ContentBlock.toolResult(
          toolCallId: tc.id!,
          toolName: tc.name!,
          content: textParts.join('\n'),
          imageBase64: imageBase64,
          imageMimeType: imageMimeType,
        ));

        if (imageBase64 != null) {
          contentBlocks.add(ContentBlock.image(
            base64Data: imageBase64,
            mimeType: imageMimeType ?? 'image/png',
          ));
        }

        return Message(
          id: generateId(),
          conversationId: conversationId,
          role: MessageRole.tool,
          content: contentBlocks,
          createdAt: DateTime.now(),
        );
      } catch (e) {
        return Message(
          id: generateId(),
          conversationId: conversationId,
          role: MessageRole.tool,
          content: [
            ContentBlock.toolResult(
              toolCallId: tc.id!,
              toolName: tc.name!,
              content: 'Error executing tool: $e',
            ),
          ],
          createdAt: DateTime.now(),
        );
      }
    });

    final results = await Future.wait(futures);
    for (final msg in results) {
      await actions.saveMessage(msg);
    }

    // Continue the conversation with tool results
    final historyAsync =
        _ref.read(conversationMessagesProvider(conversationId));
    final history = historyAsync.valueOrNull ?? [];
    final conversation = _ref.read(selectedConversationProvider);
    final settingsNow = _ref.read(settingsProvider);

    final apiMessages = _buildApiMessages(
      history: history,
      systemPrompt: conversation?.systemPrompt ??
          settingsNow.defaultSystemPrompt,
    );

    // Stream the next response
    await _streamResponse(
      conversationId: conversationId,
      apiMessages: apiMessages,
      llm: llm,
      mcpTools: mcpTools,
      mcpService: mcpService,
      settings: settingsNow,
      actions: actions,
    );
  }

  void _updateStreamingMessage(
    String id,
    String conversationId,
    String content,
    String thinking,
    Map<int, _ToolCallAccumulator> toolCalls,
  ) {
    final message = _buildAssistantMessage(
        id, conversationId, content, thinking, toolCalls,
        isStreaming: true);
    state = state.copyWith(streamingMessages: [message]);
  }

  Message _buildAssistantMessage(
    String id,
    String conversationId,
    String content,
    String thinking,
    Map<int, _ToolCallAccumulator> toolCalls, {
    required bool isStreaming,
  }) {
    final blocks = <ContentBlock>[];

    if (thinking.isNotEmpty) {
      blocks.add(ContentBlock.thinking(text: thinking));
    }
    if (content.isNotEmpty) {
      blocks.add(ContentBlock.text(text: content));
    }
    for (final tc in toolCalls.values) {
      if (tc.id != null && tc.name != null) {
        blocks.add(ContentBlock.toolCall(
          id: tc.id!,
          name: tc.name!,
          arguments: tc.argumentsBuffer.toString(),
        ));
      }
    }

    if (blocks.isEmpty) {
      blocks.add(const ContentBlock.text(text: ''));
    }

    return Message(
      id: id,
      conversationId: conversationId,
      role: MessageRole.assistant,
      content: blocks,
      createdAt: DateTime.now(),
      isStreaming: isStreaming,
    );
  }

  List<Map<String, dynamic>> _buildApiMessages({
    required List<Message> history,
    required String systemPrompt,
  }) {
    final messages = <Map<String, dynamic>>[];

    if (systemPrompt.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': systemPrompt,
      });
    }

    for (final msg in history) {
      // For tool messages that contain images, we need to include
      // the image as a user message with image_url content
      if (msg.role == MessageRole.tool) {
        messages.add(msg.toApiMessage());

        // Check if there's an image in the tool result
        for (final block in msg.content) {
          if (block is ToolResultContentBlock &&
              block.imageBase64 != null) {
            // Add image as a user message so the model can see it
            messages.add({
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {
                    'url':
                        'data:${block.imageMimeType ?? "image/png"};base64,${block.imageBase64}',
                  },
                },
                {
                  'type': 'text',
                  'text':
                      'Here is the image result from tool "${block.toolName}".',
                },
              ],
            });
          }
        }
      } else {
        messages.add(msg.toApiMessage());
      }
    }

    return messages;
  }

  /// Stop the current generation.
  void stopGeneration() {
    _cancelToken?.cancel();
    state = state.copyWith(
      isGenerating: false,
      streamingMessages: [],
    );
  }

  Future<void> _autoTitleIfNeeded(
    String conversationId,
    String assistantResponse,
    ConversationActions actions,
  ) async {
    final conversation = _ref.read(selectedConversationProvider);
    if (conversation == null || conversation.title != 'New Chat') return;

    // Use a simple heuristic: first line, truncated
    final firstLine = assistantResponse.split('\n').first.trim();
    if (firstLine.isEmpty) return;

    final title = firstLine.length > 50
        ? '${firstLine.substring(0, 47)}...'
        : firstLine;
    await actions.renameConversation(conversationId, title);
  }
}

class _ToolCallAccumulator {
  String? id;
  String? name;
  final StringBuffer argumentsBuffer = StringBuffer();
}
