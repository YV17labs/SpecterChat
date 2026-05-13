import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../services/chat_logic.dart';
import '../services/i_llm_service.dart';
import '../services/llm_hooks/llm_hooks.dart' as llm_hooks;
import '../services/tool_executor.dart';
import '../utils/id_gen.dart';
import 'chat_session_deps.dart';
import 'chat_session_state.dart';

final _log = Logger('ChatSession');

/// A long-lived streaming worker scoped to a single conversation.
///
/// The session is completely independent of the UI and of Riverpod.
/// Its lifecycle is owned by [ChatSessionManager]:
///
///   manager.sendMessage(convId, text)
///     └─> session.sendMessage(text, deps)
///           ├─> persists the user message
///           ├─> streams the assistant response, upserting a placeholder
///           │   row every ~120ms so the UI (which watches the messages
///           │   table) sees content grow live
///           ├─> runs any tool calls, then recurses into the LLM again
///           └─> finalises the placeholder row (flips is_streaming = 0)
///
/// The UI observes [state] (a [ValueNotifier]) for coarse lifecycle and
/// reads actual message content from Drift. Switching conversations in
/// the UI does NOT cancel or dispose the session — it keeps running in
/// the manager's registry until it finishes on its own or the manager
/// evicts it.
class ChatSession {
  ChatSession({
    required this.conversationId,
    required ChatSessionDepsResolver resolveDeps,
    ChatLogic logic = const ChatLogic(),
    ToolExecutor toolExecutor = const ToolExecutor(),
    Duration persistenceThrottle = const Duration(milliseconds: 120),
  })  : _resolveDeps = resolveDeps,
        _logic = logic,
        _toolExecutor = toolExecutor,
        _persistenceInterval = persistenceThrottle;

  final String conversationId;
  final ChatSessionDepsResolver _resolveDeps;
  final ChatLogic _logic;
  final ToolExecutor _toolExecutor;
  final Duration _persistenceInterval;

  /// Observable lifecycle state. UI listens but content lives in Drift.
  final ValueNotifier<ChatSessionState> state =
      ValueNotifier(const SessionIdle());

  // ---------------------------------------------------------------------
  // Liveness tracking — the manager uses [lastActivity] for LRU eviction.
  // ---------------------------------------------------------------------
  DateTime lastActivity = DateTime.now();
  bool get isGenerating => state.value is SessionStreaming;
  bool _disposed = false;

  // ---------------------------------------------------------------------
  // Per-send streaming state. Reset at the start of every top-level send.
  // ---------------------------------------------------------------------
  CancelToken? _cancelToken;
  Timer? _throttleTimer;
  bool _dirty = false;
  int _lastPersistedContentLen = -1;
  int _lastPersistedThinkingLen = -1;

  // Buffers for the current in-flight stream.
  String? _streamingMessageId;
  final _contentBuffer = StringBuffer();
  final _thinkingBuffer = StringBuffer();
  Map<int, ToolCallAccumulator> _toolCalls = {};
  Stopwatch _stopwatch = Stopwatch();

  // Image bytes accumulated across the tool-loop iterations of a single
  // send. Cleared when the send finalises so bytes don't outlive the
  // pipeline (each image can be several MB).
  final Map<String, ImageBytes> _imageBytes = {};

  static final _toolNameNoise = RegExp(r'[(\n<]');

  // =====================================================================
  // Public API
  // =====================================================================

  /// Restore token counts from the persisted `lastPromptTokens` on the
  /// conversation row. Called once when the manager first materialises
  /// the session, so the context gauge does not flash zero.
  Future<void> hydrate(Conversation conversation) async {
    if (_disposed) return;
    if (conversation.lastPromptTokens > 0) {
      state.value = SessionIdle(promptTokens: conversation.lastPromptTokens);
    }
  }

  /// Send a user message and stream the response. Safe to call again
  /// once the previous send resolves. If the session is already
  /// streaming, the call is ignored — the manager is expected to wait
  /// for [isGenerating] to be false.
  Future<void> sendMessage(String userText) async {
    if (_disposed) return;
    if (isGenerating) {
      _log.warning('sendMessage ignored — session already streaming');
      return;
    }
    lastActivity = DateTime.now();

    final deps = _resolveDeps();

    _transitionToStreaming();

    try {
      final userMessage = Message(
        id: generateId(),
        conversationId: conversationId,
        role: MessageRole.user,
        content: [ContentBlock.text(text: userText)],
        createdAt: DateTime.now(),
      );
      await deps.repo.saveMessage(userMessage);

      _cancelToken = CancelToken();
      await _runPipeline(deps);
    } catch (e, st) {
      _log.severe('sendMessage failed', e, st);
      _emitError('$e');
    } finally {
      _stopThrottle();
      if (state.value is SessionStreaming) {
        state.value = SessionIdle(
          promptTokens: state.value.promptTokens,
          completionTokens: state.value.completionTokens,
        );
      }
      _cancelToken = null;
      _imageBytes.clear();
    }
  }

  /// Cancel the in-flight stream. Partial text content is kept so the
  /// user still sees what arrived before the cancel.
  Future<void> stop() async {
    if (!isGenerating) return;
    _log.info('Stopping session $conversationId');
    _cancelToken?.cancel('user-stop');
    _stopThrottle();
    try {
      await _cleanupAfterInterruption(_resolveDeps());
    } catch (e, st) {
      _log.fine('stop cleanup failed', e, st);
    }
  }

  /// Clear a transient error so the UI banner can be dismissed.
  void clearError() {
    if (state.value is SessionError) {
      state.value = SessionIdle(
        promptTokens: state.value.promptTokens,
        completionTokens: state.value.completionTokens,
      );
    }
  }

  /// Release resources and cancel any in-flight stream. The session
  /// must not be reused after dispose.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelToken?.cancel('session-dispose');
    _stopThrottle();
    try {
      await _cleanupAfterInterruption(_resolveDeps());
    } catch (e, st) {
      _log.fine('dispose cleanup failed', e, st);
    }
    state.dispose();
  }

  // =====================================================================
  // Pipeline internals
  // =====================================================================

  void _transitionToStreaming() {
    state.value = SessionStreaming(
      streamingMessageId: '',
      promptTokens: state.value.promptTokens,
      completionTokens: state.value.completionTokens,
    );
  }

  void _emitError(String message) {
    state.value = SessionError(
      message: message,
      promptTokens: state.value.promptTokens,
      completionTokens: state.value.completionTokens,
    );
  }

  /// Pipeline entry. Rebuilds API messages from DB history, then streams
  /// one LLM response. Recurses for tool-call continuations.
  Future<void> _runPipeline(
    ChatSessionDeps deps, {
    int hallucinationRetry = 0,
  }) async {
    final history = await deps.repo.getMessages(conversationId);
    final imageIds = _logic.collectImageAttachmentIds(history);
    // Only fetch bytes for ids we don't already hold from an earlier
    // turn — tool-loop recursion revisits the same attachments many
    // times per send, and each image can be several MB.
    final missing =
        imageIds.where((id) => !_imageBytes.containsKey(id)).toSet();
    if (missing.isNotEmpty) {
      _imageBytes.addAll(await deps.attachments.loadMany(missing));
    }
    final apiMessages = _logic.buildApiMessages(
      history: history,
      systemPrompt: deps.mergedSystemPrompt,
      imageBytes: _imageBytes,
    );

    await _streamResponse(
      deps: deps,
      apiMessages: apiMessages,
      hallucinationRetry: hallucinationRetry,
    );
  }

  Future<void> _streamResponse({
    required ChatSessionDeps deps,
    required List<Map<String, dynamic>> apiMessages,
    required int hallucinationRetry,
  }) async {
    _resetBuffers();
    _streamingMessageId = generateId();
    _stopwatch = Stopwatch()..start();
    int completionTokens = 0;

    // Publish the streaming id so the UI can flag the live message.
    state.value = SessionStreaming(
      streamingMessageId: _streamingMessageId!,
      promptTokens: state.value.promptTokens,
      completionTokens: state.value.completionTokens,
    );

    // Create the placeholder row immediately — the UI shows a typing
    // indicator as soon as the user sends.
    await _persistCurrentBuffer(deps, force: true);
    _startThrottle(deps);

    await for (final event in deps.llm.streamChatCompletion(
      messages: apiMessages,
      tools: deps.mcpTools.isNotEmpty ? deps.mcpTools : null,
      cancelToken: _cancelToken,
    )) {
      lastActivity = DateTime.now();

      switch (event) {
        case ContentDelta(:final text):
          _contentBuffer.write(text);
          _dirty = true;

        case ThinkingDelta(:final text):
          _thinkingBuffer.write(text);
          _dirty = true;

        case ToolCallDelta(
            :final index,
            :final id,
            :final name,
            :final argumentsDelta
          ):
          final isNew = !_toolCalls.containsKey(index);
          final tc = _toolCalls.putIfAbsent(index, ToolCallAccumulator.new);
          if (id != null) tc.id = id;
          if (name != null) {
            final clean = name.split(_toolNameNoise).first.trim();
            tc.name = clean.isNotEmpty ? clean : name;
          }
          tc.argumentsBuffer.write(argumentsDelta);
          _dirty = true;
          // Flush immediately on first delta so the tool name appears
          // without waiting for the throttle window.
          if (isNew) await _persistCurrentBuffer(deps, force: true);

        case StreamUsage(:final promptTokens, completionTokens: final ct):
          completionTokens = ct;
          state.value = SessionStreaming(
            streamingMessageId: _streamingMessageId!,
            promptTokens: promptTokens,
            completionTokens: ct,
          );

        case StreamDone():
          await _handleStreamDone(
            deps: deps,
            completionTokens: completionTokens,
            hallucinationRetry: hallucinationRetry,
          );
          return;

        case StreamError(:final message):
          _stopThrottle();
          await _cleanupAfterInterruption(deps);
          _emitError(message);
          return;
      }
    }

    // Stream ended without StreamDone (rare) — treat as completion.
    await _handleStreamDone(
      deps: deps,
      completionTokens: completionTokens,
      hallucinationRetry: hallucinationRetry,
    );
  }

  Future<void> _handleStreamDone({
    required ChatSessionDeps deps,
    required int completionTokens,
    required int hallucinationRetry,
  }) async {
    _stopThrottle();
    _stopwatch.stop();

    final contentString = _contentBuffer.toString();
    final thinkingString = _thinkingBuffer.toString();

    final modelName = deps.settings.api.selectedModel;
    final hook = llm_hooks.hookFor(modelName);
    final hasHallucination = hook != null &&
        (hook.detectHallucination(contentString) ||
            hook.detectHallucination(thinkingString));
    final hasValidToolCalls =
        _toolCalls.values.any((tc) => tc.isValid);
    final isSendable = contentString.isNotEmpty || hasValidToolCalls;
    // Symptom-based fallback: the server may strip a malformed tool-call
    // wrapper before any of it reaches us (mlx_vlm does this when Qwen3
    // emits XML-style arguments inside <tool_call>…</tool_call> — see
    // server.py:`suppress_tool_call_content`). The visible result is an
    // otherwise-empty turn where the model clearly thought but produced
    // nothing usable. Treat it as a hallucination and retry on the same
    // budget as the pattern-matched path.
    final hasSuppressedHallucination = hook != null &&
        !hasHallucination &&
        !isSendable &&
        thinkingString.isNotEmpty;

    await _commitOrDropPlaceholder(
      deps: deps,
      keep: isSendable && !hasHallucination,
      completionTokens: completionTokens,
    );

    // Persist the latest prompt token count for the context gauge.
    if (state.value.promptTokens > 0) {
      deps.repo
          .updateLastPromptTokens(conversationId, state.value.promptTokens)
          .ignore();
    }

    if (hasValidToolCalls && !hasHallucination) {
      await _continueWithToolResults(deps);
      return;
    }

    if ((hasHallucination || hasSuppressedHallucination) &&
        hallucinationRetry < llm_hooks.maxHallucinationRetries) {
      _log.warning(
        '${hasHallucination ? "Hallucinated tool-call XML" : "Suppressed tool-call (empty turn)"} '
        '(retry ${hallucinationRetry + 1}/${llm_hooks.maxHallucinationRetries})',
      );
      await _retryAfterHallucination(
        deps: deps,
        nextRetry: hallucinationRetry + 1,
      );
      return;
    }

    await _autoTitleIfNeeded(deps, contentString);
  }

  /// Flip the streaming placeholder row to its finalised form (same id,
  /// `is_streaming=0`, full token/duration info) when [keep] is true —
  /// otherwise drop the row so it doesn't linger in the conversation.
  Future<void> _commitOrDropPlaceholder({
    required ChatSessionDeps deps,
    required bool keep,
    required int completionTokens,
  }) async {
    if (!keep) {
      await _deletePlaceholder(deps);
      return;
    }
    final finalMessage = _logic.buildAssistantMessage(
      id: _streamingMessageId!,
      conversationId: conversationId,
      content: _contentBuffer.toString(),
      thinking: _thinkingBuffer.toString(),
      toolCalls: _toolCalls,
      isStreaming: false,
      completionTokens: completionTokens,
      durationMs: _stopwatch.elapsedMilliseconds,
    );
    await deps.repo.upsertStreamingMessage(finalMessage);
    await deps.repo.finalizeStreamingMessage(_streamingMessageId!);
  }

  Future<void> _continueWithToolResults(ChatSessionDeps deps) async {
    await _toolExecutor.executeAndSave(
      conversationId: conversationId,
      toolCalls: _toolCalls,
      mcpService: deps.mcpService,
      mcpServers: deps.mcpServers,
      repo: deps.repo,
      attachments: deps.attachments,
    );
    await _runPipeline(deps);
  }

  Future<void> _retryAfterHallucination({
    required ChatSessionDeps deps,
    required int nextRetry,
  }) async {
    final modelName = deps.settings.api.selectedModel;
    final correction = Message(
      id: generateId(),
      conversationId: conversationId,
      role: MessageRole.user,
      content: [
        ContentBlock.text(
            text: llm_hooks.hallucinationCorrection(modelName)),
      ],
      createdAt: DateTime.now(),
    );
    await deps.repo.saveMessage(correction);
    await _runPipeline(deps, hallucinationRetry: nextRetry);
  }

  Future<void> _autoTitleIfNeeded(
      ChatSessionDeps deps, String assistantResponse) async {
    final conversation = await deps.repo.getConversation(conversationId);
    if (conversation == null) return;
    if (conversation.title != kDefaultConversationTitle) return;

    final title = _logic.generateAutoTitle(assistantResponse);
    if (title != null) {
      await deps.repo.renameConversation(conversationId, title);
    }
  }

  // =====================================================================
  // Incremental persistence throttle
  // =====================================================================

  void _startThrottle(ChatSessionDeps deps) {
    _throttleTimer ??= Timer.periodic(_persistenceInterval, (_) {
      _persistCurrentBuffer(deps).ignore();
    });
  }

  void _stopThrottle() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
  }

  Future<void> _persistCurrentBuffer(
    ChatSessionDeps deps, {
    bool force = false,
  }) async {
    if (_streamingMessageId == null) return;
    if (!force && !_dirty) return;

    final contentLen = _contentBuffer.length;
    final thinkingLen = _thinkingBuffer.length;
    final toolDirty = _toolCalls.isNotEmpty;
    if (!force &&
        contentLen == _lastPersistedContentLen &&
        thinkingLen == _lastPersistedThinkingLen &&
        !toolDirty) {
      _dirty = false;
      return;
    }

    _dirty = false;
    _lastPersistedContentLen = contentLen;
    _lastPersistedThinkingLen = thinkingLen;

    final partial = _logic.buildAssistantMessage(
      id: _streamingMessageId!,
      conversationId: conversationId,
      content: _contentBuffer.toString(),
      thinking: _thinkingBuffer.toString(),
      toolCalls: _toolCalls,
      isStreaming: true,
    );
    try {
      await deps.repo.upsertStreamingMessage(partial);
    } catch (e, st) {
      _log.warning('Partial persist failed', e, st);
    }
  }

  void _dropIncompleteToolCalls() {
    _toolCalls.removeWhere(
        (_, tc) => !hasParseableToolCallArgs(tc.argumentsBuffer.toString()));
  }

  Future<void> _cleanupAfterInterruption(ChatSessionDeps deps) async {
    _dropIncompleteToolCalls();
    final hasValidToolCalls = _toolCalls.values.any((tc) => tc.isValid);
    final isSendable = _contentBuffer.isNotEmpty || hasValidToolCalls;
    if (isSendable) {
      await _persistCurrentBuffer(deps, force: true);
      await _finalizePlaceholder();
    } else {
      await _deletePlaceholder(deps);
    }
  }

  Future<void> _finalizePlaceholder() async {
    if (_streamingMessageId == null) return;
    try {
      final deps = _resolveDeps();
      await deps.repo.finalizeStreamingMessage(_streamingMessageId!);
    } catch (e, st) {
      _log.fine('finalizePlaceholder failed', e, st);
    }
  }

  Future<void> _deletePlaceholder(ChatSessionDeps deps) async {
    if (_streamingMessageId == null) return;
    try {
      await deps.repo.deleteMessage(_streamingMessageId!);
    } catch (e, st) {
      _log.fine('deletePlaceholder failed', e, st);
    }
  }

  void _resetBuffers() {
    _contentBuffer.clear();
    _thinkingBuffer.clear();
    _toolCalls = {};
    _lastPersistedContentLen = -1;
    _lastPersistedThinkingLen = -1;
    _dirty = false;
  }
}
