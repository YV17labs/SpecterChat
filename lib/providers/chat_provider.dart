import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../database/i_conversation_repository.dart';
import '../models/app_settings.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../services/chat_logic.dart';
import '../services/i_llm_service.dart';
import '../services/i_mcp_service.dart';
import '../services/tool_executor.dart';
import '../utils/id_gen.dart';
import 'conversation_provider.dart';
import 'llm_provider.dart';
import 'mcp_provider.dart';
import 'settings_provider.dart';

final _log = Logger('ChatProvider');

const _sentinel = Object();

/// Holds the current streaming state for the active chat.
class ChatState {
  final List<Message> streamingMessages;
  final bool isGenerating;
  final String? error;
  final int promptTokens;
  final int completionTokens;

  const ChatState({
    this.streamingMessages = const [],
    this.isGenerating = false,
    this.error,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  int get totalTokens => promptTokens + completionTokens;

  ChatState copyWith({
    List<Message>? streamingMessages,
    bool? isGenerating,
    Object? error = _sentinel,
    int? promptTokens,
    int? completionTokens,
  }) {
    return ChatState(
      streamingMessages: streamingMessages ?? this.streamingMessages,
      isGenerating: isGenerating ?? this.isGenerating,
      error: identical(error, _sentinel) ? this.error : error as String?,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
    );
  }
}

final chatProvider =
    NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);

class ChatNotifier extends Notifier<ChatState> {
  final ChatLogic _logic = const ChatLogic();
  static final _toolNameNoise = RegExp(r'[(\n<]');
  final ToolExecutor _toolExecutor = const ToolExecutor();
  CancelToken? _cancelToken;
  Timer? _streamingThrottle;
  bool _streamingDirty = false;
  int _lastFlushedContentLen = 0;
  int _lastFlushedThinkingLen = 0;

  @override
  ChatState build() {
    // Cancel any in-flight generation and reset state on conversation switch.
    ref.listen(selectedConversationIdProvider, (prev, next) {
      if (prev != next) {
        _cancelToken?.cancel();
        _stopStreamingThrottle();
        state = const ChatState();
      }
    });
    ref.onDispose(() {
      _log.info('ChatNotifier disposed — cancelling in-flight work');
      _cancelToken?.cancel();
      _streamingThrottle?.cancel();
    });
    return const ChatState();
  }

  /// Send a user message and stream the assistant's response.
  Future<void> sendMessage(
      String conversationId, String userText) async {
    if (state.isGenerating) return;

    state = state.copyWith(isGenerating: true, error: null);

    try {
      final repo = ref.read(conversationRepositoryProvider);
      final llm = ref.read(llmServiceProvider);
      final settings = ref.read(settingsProvider);
      final mcpService = ref.read(mcpServiceProvider);
      final mcpTools = ref.read(mcpToolsProvider);

      final userMessage = Message(
        id: generateId(),
        conversationId: conversationId,
        role: MessageRole.user,
        content: [ContentBlock.text(text: userText)],
        createdAt: DateTime.now(),
      );
      await repo.saveMessage(userMessage);

      final conversation = ref.read(selectedConversationProvider);
      final historyAsync =
          ref.read(conversationMessagesProvider(conversationId));
      final history = historyAsync.value ?? [];

      final apiMessages = _logic.buildApiMessages(
        history: [...history, userMessage],
        systemPrompt: _buildSystemPrompt(
          conversation?.systemPrompt ?? settings.defaultSystemPrompt,
        ),
      );

      _cancelToken = CancelToken();

      await _streamResponse(
        conversationId: conversationId,
        apiMessages: apiMessages,
        llm: llm,
        mcpTools: mcpTools,
        mcpService: mcpService,
        settings: settings,
        repo: repo,
      );
    } catch (e, st) {
      _log.severe('Error sending message', e, st);
      state = state.copyWith(
        error: '$e',
      );
    } finally {
      _stopStreamingThrottle();
      state = state.copyWith(
        isGenerating: false,
        streamingMessages: [],
      );
    }
  }

  /// Stop the current generation.
  void stopGeneration() {
    _cancelToken?.cancel();
    _stopStreamingThrottle();
    state = state.copyWith(
      isGenerating: false,
      streamingMessages: [],
    );
  }

  /// Dismiss the error banner.
  void clearError() {
    state = state.copyWith(error: null);
  }

  // ---------------------------------------------------------------------------
  // Private — streaming
  // ---------------------------------------------------------------------------

  Future<void> _streamResponse({
    required String conversationId,
    required List<Map<String, dynamic>> apiMessages,
    required ILlmService llm,
    required List<Map<String, dynamic>> mcpTools,
    required IMcpService mcpService,
    required AppSettings settings,
    required IConversationRepository repo,
  }) async {
    final contentBuffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    final toolCalls = <int, ToolCallAccumulator>{};
    final stopwatch = Stopwatch()..start();
    int completionTokens = 0;

    final assistantId = generateId();

    // Show a streaming placeholder immediately (3-dot animation).
    _scheduleStreamingUpdate(
        assistantId, conversationId, contentBuffer, thinkingBuffer, toolCalls);
    _lastFlushedContentLen = -1;
    _flushStreamingUpdate();

    await for (final event in llm.streamChatCompletion(
      messages: apiMessages,
      tools: mcpTools.isNotEmpty ? mcpTools : null,
      cancelToken: _cancelToken,
    )) {
      switch (event) {
        case ContentDelta(:final text):
          contentBuffer.write(text);

        case ThinkingDelta(:final text):
          thinkingBuffer.write(text);

        case ToolCallDelta(
            :final index,
            :final id,
            :final name,
            :final argumentsDelta
          ):
          final isNew = !toolCalls.containsKey(index);
          toolCalls.putIfAbsent(index, () => ToolCallAccumulator());
          final tc = toolCalls[index]!;
          if (id != null) tc.id = id;
          // Some models emit the tool name with trailing noise
          // like "screenshot()\n</function". Strip it.
          if (name != null) {
            final clean = name.split(_toolNameNoise).first.trim();
            tc.name = clean.isNotEmpty ? clean : name;
          }
          tc.argumentsBuffer.write(argumentsDelta);
          // Flush immediately on first delta so tool name appears
          // without delay; subsequent argument chunks use the throttle.
          if (isNew) _flushStreamingUpdate();

        case StreamUsage(
            :final promptTokens,
            completionTokens: final ct
          ):
          completionTokens = ct;
          state = state.copyWith(
            promptTokens: promptTokens,
            completionTokens: ct,
          );

        case StreamDone():
          _stopStreamingThrottle();
          stopwatch.stop();
          final hasContent = contentBuffer.isNotEmpty ||
              thinkingBuffer.isNotEmpty ||
              toolCalls.isNotEmpty;

          if (hasContent) {
            final assistantMessage = _logic.buildAssistantMessage(
              id: assistantId,
              conversationId: conversationId,
              content: contentBuffer.toString(),
              thinking: thinkingBuffer.toString(),
              toolCalls: toolCalls,
              isStreaming: false,
              completionTokens: completionTokens,
              durationMs: stopwatch.elapsedMilliseconds,
            );
            await repo.saveMessage(assistantMessage);
          }
          state = state.copyWith(streamingMessages: []);

          if (toolCalls.isNotEmpty) {
            await _continueWithToolResults(
              conversationId: conversationId,
              toolCalls: toolCalls,
              mcpService: mcpService,
              settings: settings,
              llm: llm,
              mcpTools: mcpTools,
              repo: repo,
            );
          } else {
            _autoTitleIfNeeded(
                conversationId, contentBuffer.toString(), repo)
                .ignore();
          }
          return;

        case StreamError(:final message):
          _stopStreamingThrottle();
          state = state.copyWith(
            error: message,
          );
          return;
      }

      // Mark dirty — throttled timer will flush to UI.
      _streamingDirty = true;
    }

    _stopStreamingThrottle();
  }

  // ---------------------------------------------------------------------------
  // Private — tool call orchestration
  // ---------------------------------------------------------------------------

  Future<void> _continueWithToolResults({
    required String conversationId,
    required Map<int, ToolCallAccumulator> toolCalls,
    required IMcpService mcpService,
    required AppSettings settings,
    required ILlmService llm,
    required List<Map<String, dynamic>> mcpTools,
    required IConversationRepository repo,
  }) async {
    await _toolExecutor.executeAndSave(
      conversationId: conversationId,
      toolCalls: toolCalls,
      mcpService: mcpService,
      mcpServers: settings.mcpServers,
      repo: repo,
    );

    // Direct DB read to ensure tool results are included (stream
    // provider may not have emitted yet).
    final history = await repo.getMessages(conversationId);
    final conversation = ref.read(selectedConversationProvider);
    final settingsNow = ref.read(settingsProvider);

    final apiMessages = _logic.buildApiMessages(
      history: history,
      systemPrompt: _buildSystemPrompt(
        conversation?.systemPrompt ?? settingsNow.defaultSystemPrompt,
      ),
    );

    await _streamResponse(
      conversationId: conversationId,
      apiMessages: apiMessages,
      llm: llm,
      mcpTools: mcpTools,
      mcpService: mcpService,
      settings: settingsNow,
      repo: repo,
    );
  }

  // ---------------------------------------------------------------------------
  // Private — helpers
  // ---------------------------------------------------------------------------

  /// Pending args for the next throttled UI flush.
  ({String id, String conversationId, StringBuffer content,
      StringBuffer thinking, Map<int, ToolCallAccumulator> toolCalls})?
      _pendingStreaming;

  /// Schedule a throttled streaming UI update (~50ms).
  void _scheduleStreamingUpdate(
    String id,
    String conversationId,
    StringBuffer content,
    StringBuffer thinking,
    Map<int, ToolCallAccumulator> toolCalls,
  ) {
    _pendingStreaming = (
      id: id,
      conversationId: conversationId,
      content: content,
      thinking: thinking,
      toolCalls: toolCalls,
    );
    _streamingDirty = true;
    _lastFlushedContentLen = 0;
    _lastFlushedThinkingLen = 0;
    _streamingThrottle ??=
        Timer.periodic(const Duration(milliseconds: 50), (_) {
      _flushStreamingUpdate();
    });
  }

  void _flushStreamingUpdate() {
    if (!_streamingDirty || _pendingStreaming == null) return;
    _streamingDirty = false;
    final p = _pendingStreaming!;
    final contentLen = p.content.length;
    final thinkingLen = p.thinking.length;
    if (contentLen == _lastFlushedContentLen &&
        thinkingLen == _lastFlushedThinkingLen) {
      return;
    }
    _lastFlushedContentLen = contentLen;
    _lastFlushedThinkingLen = thinkingLen;
    final message = _logic.buildAssistantMessage(
      id: p.id,
      conversationId: p.conversationId,
      content: p.content.toString(),
      thinking: p.thinking.toString(),
      toolCalls: p.toolCalls,
      isStreaming: true,
    );
    state = state.copyWith(streamingMessages: [message]);
  }

  void _stopStreamingThrottle() {
    _streamingThrottle?.cancel();
    _streamingThrottle = null;
    _flushStreamingUpdate();
    _pendingStreaming = null;
  }

  String _buildSystemPrompt(String basePrompt) {
    final mcpInstructions = ref.read(mcpInstructionsProvider);
    if (mcpInstructions.isEmpty) return basePrompt;
    return basePrompt.isEmpty
        ? mcpInstructions
        : '$basePrompt\n\n$mcpInstructions';
  }

  Future<void> _autoTitleIfNeeded(
    String conversationId,
    String assistantResponse,
    IConversationRepository repo,
  ) async {
    final conversation = ref.read(selectedConversationProvider);
    if (conversation == null ||
        conversation.title != kDefaultConversationTitle) {
      return;
    }

    final title = _logic.generateAutoTitle(assistantResponse);
    if (title != null) {
      await repo.renameConversation(conversationId, title);
    }
  }
}
