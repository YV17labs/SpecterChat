import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../core/id_gen.dart';
import '../../domain/chat_session_state.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/message.dart';
import '../../domain/services/cancellation_token.dart';
import '../../domain/services/i_llm_service.dart';
import '../mcp/active_mcp_server.dart';
import 'chat_logic.dart';
import 'chat_session_deps.dart';
import 'stream_accumulator.dart';
import 'streaming_persister.dart';
import 'tool_executor.dart';

final _log = Logger('ChatSession');

/// A long-lived streaming worker scoped to a single conversation.
///
/// The session is completely independent of the UI and of Riverpod.
/// Its lifecycle is owned by `ChatSessionManager`:
///
///   manager.sendMessage(convId, text)
///     └─> session.sendMessage(text)
///           ├─> persists the user message
///           ├─> streams the assistant response; a [StreamingPersister]
///           │   upserts a placeholder row every ~120ms so the UI (which
///           │   watches the messages table) sees content grow live
///           ├─> runs any tool calls, then recurses into the LLM again
///           └─> finalises the placeholder row (flips is_streaming = 0)
///
/// The UI observes [state] (a [ValueNotifier]) for coarse lifecycle and
/// reads actual message content from the database. Switching conversations
/// in the UI does NOT cancel or dispose the session — it keeps running in
/// the manager's registry until it finishes on its own or the manager
/// evicts it.
class ChatSession {
  ChatSession({
    required this.conversationId,
    required ChatSessionDepsResolver resolveDeps,
    ChatLogic logic = const ChatLogic(),
    ToolExecutor toolExecutor = const ToolExecutor(),
    Duration persistenceThrottle = const Duration(milliseconds: 120),
  }) : _resolveDeps = resolveDeps,
       _logic = logic,
       _toolExecutor = toolExecutor,
       _persistenceInterval = persistenceThrottle;

  final String conversationId;
  final ChatSessionDepsResolver _resolveDeps;
  final ChatLogic _logic;
  final ToolExecutor _toolExecutor;
  final Duration _persistenceInterval;

  /// Observable lifecycle state. UI listens but content lives in the DB.
  final ValueNotifier<ChatSessionState> state = ValueNotifier(
    const SessionIdle(),
  );

  /// The manager uses this for LRU eviction.
  DateTime lastActivity = DateTime.now();
  bool get isGenerating => state.value is SessionStreaming;
  bool _disposed = false;

  // Per-send state. Reset at the start of every top-level send.
  CancellationToken? _cancellation;
  Future<void>? _inFlight;
  final StreamAccumulator _accumulator = StreamAccumulator();
  StreamingPersister? _persister;
  Stopwatch _stopwatch = Stopwatch();

  // Image bytes accumulated across the tool-loop iterations of a single
  // send. Cleared when the send finalises so bytes don't outlive the
  // pipeline (each image can be several MB).
  final Map<String, ImageBytes> _imageBytes = {};

  bool get _isCancelled => _cancellation?.isCancelled ?? false;

  // =====================================================================
  // Public API
  // =====================================================================

  /// Restore token counts from the persisted `lastPromptTokens` on the
  /// conversation row. Called once when the manager first materialises
  /// the session, so the context gauge does not flash zero.
  void hydrate(Conversation conversation) {
    if (_disposed) return;
    if (conversation.lastPromptTokens > 0) {
      state.value = SessionIdle(promptTokens: conversation.lastPromptTokens);
    }
  }

  /// Send a user message and stream the response. Resolves once the whole
  /// turn — including tool-call rounds — has finished. Ignored while a
  /// previous send is still streaming.
  Future<void> sendMessage(String userText) async {
    if (_disposed) return;
    if (isGenerating) {
      _log.warning('sendMessage ignored — session already streaming');
      return;
    }
    lastActivity = DateTime.now();
    final deps = _resolveDeps();
    state.value = state.value.toStreaming('');
    _inFlight = _send(userText, deps);
    await _inFlight;
  }

  /// Cancel the in-flight turn and wait for it to settle. Partial text
  /// content is kept so the user still sees what arrived before the stop;
  /// tool calls that were about to run are not run.
  Future<void> stop() async {
    if (!isGenerating) return;
    _log.info('Stopping session $conversationId');
    _cancellation?.cancel();
    await _inFlight;
  }

  /// Clear a transient error so the UI banner can be dismissed.
  void clearError() {
    if (state.value is SessionError) state.value = state.value.toIdle();
  }

  /// Release resources and cancel any in-flight stream. The session
  /// must not be reused after dispose.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancellation?.cancel();
    await _inFlight;
    state.dispose();
  }

  // =====================================================================
  // Turn lifecycle
  // =====================================================================

  Future<void> _send(String userText, ChatSessionDeps deps) async {
    try {
      await deps.messages.saveMessage(_userMessage(userText));
      _cancellation = CancellationToken();
      await _runPipeline(deps);
    } catch (e, st) {
      _log.severe('sendMessage failed', e, st);
      state.value = state.value.toError('$e');
    } finally {
      // The persister stops itself on every normal ending; this covers an
      // exception thrown mid-stream, which would otherwise leave its
      // timer running.
      _persister?.stop();
      _persister = null;
      _cancellation = null;
      _imageBytes.clear();
      if (state.value is SessionStreaming) state.value = state.value.toIdle();
    }
  }

  Message _userMessage(String text) => Message(
    id: generateId(),
    conversationId: conversationId,
    role: MessageRole.user,
    content: [ContentBlock.text(text: text)],
    createdAt: DateTime.now(),
  );

  /// Pipeline entry. Rebuilds the history from the DB, then streams one
  /// LLM response. Recurses for tool-call continuations.
  Future<void> _runPipeline(
    ChatSessionDeps deps, {
    int hallucinationRetry = 0,
  }) async {
    if (_isCancelled) return;
    final history = await deps.messages.getMessages(conversationId);
    final imageIds = _logic.collectImageAttachmentIds(history);
    // Only fetch bytes for ids we don't already hold from an earlier
    // turn — tool-loop recursion revisits the same attachments many
    // times per send, and each image can be several MB.
    final missing = imageIds.where((id) => !_imageBytes.containsKey(id));
    if (missing.isNotEmpty) {
      _imageBytes.addAll(await deps.attachments.loadMany(missing));
    }
    await _streamResponse(
      deps: deps,
      history: history,
      hallucinationRetry: hallucinationRetry,
    );
  }

  Future<void> _streamResponse({
    required ChatSessionDeps deps,
    required List<Message> history,
    required int hallucinationRetry,
  }) async {
    _accumulator.reset();
    final messageId = generateId();
    final persister = _persister = StreamingPersister(
      messageId: messageId,
      conversationId: conversationId,
      accumulator: _accumulator,
      messages: deps.messages,
      logic: _logic,
      interval: _persistenceInterval,
    );
    _stopwatch = Stopwatch()..start();
    var completionTokens = 0;

    // Publish the streaming id so the UI can flag the live message.
    state.value = state.value.toStreaming(messageId);

    // Create the placeholder row immediately — the UI shows a typing
    // indicator as soon as the user sends.
    await persister.flush(force: true);
    persister.start();

    final events = deps.llm.streamChatCompletion(
      history: history,
      systemPrompt: deps.mergedSystemPrompt,
      imageBytes: _imageBytes,
      tools: enabledToolsOf(deps.activeServers),
      cancellationToken: _cancellation,
    );

    await for (final event in events) {
      lastActivity = DateTime.now();
      switch (event) {
        case ContentDelta(:final text):
          _accumulator.addContent(text);
        case ThinkingDelta(:final text):
          _accumulator.addThinking(text);
        case ToolCallDelta():
          if (_accumulator.addToolCallDelta(event)) {
            await persister.flush(force: true);
          }
        case StreamUsage(:final promptTokens, completionTokens: final ct):
          completionTokens = ct;
          state.value = SessionStreaming(
            streamingMessageId: messageId,
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
        case StreamCancelled():
          await _cleanupAfterInterruption();
          return;
        case StreamError(:final message):
          await _cleanupAfterInterruption();
          state.value = state.value.toError(message);
          return;
      }
    }

    // Stream ended without a terminal event (rare) — treat as completion.
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
    final persister = _persister!;
    _stopwatch.stop();

    final analysis = _logic.analyzeCompletion(_accumulator, hook: deps.hook);

    if (analysis.keepMessage) {
      await persister.commit(
        completionTokens: completionTokens,
        durationMs: _stopwatch.elapsedMilliseconds,
      );
    } else {
      await persister.discard();
    }

    // Persist the latest prompt token count for the context gauge.
    if (state.value.promptTokens > 0) {
      deps.conversations
          .updateLastPromptTokens(conversationId, state.value.promptTokens)
          .ignore();
    }

    if (_isCancelled) return;

    if (analysis.shouldRunTools) {
      await _continueWithToolResults(deps);
      return;
    }

    if (analysis.shouldRetry &&
        hallucinationRetry < deps.hooks.maxHallucinationRetries) {
      _log.warning(
        '${analysis.hallucinated ? "Hallucinated tool-call XML" : "Suppressed tool-call (empty turn)"} '
        '(retry ${hallucinationRetry + 1}/${deps.hooks.maxHallucinationRetries})',
      );
      await _retryAfterHallucination(
        deps: deps,
        nextRetry: hallucinationRetry + 1,
      );
      return;
    }

    await _autoTitleIfNeeded(deps, _accumulator.content.toString());
  }

  Future<void> _continueWithToolResults(ChatSessionDeps deps) async {
    await _toolExecutor.executeAndSave(
      conversationId: conversationId,
      toolCalls: _accumulator.toolCalls,
      mcpService: deps.mcpService,
      servers: deps.activeServers,
      messages: deps.messages,
      attachments: deps.attachments,
    );
    await _runPipeline(deps);
  }

  Future<void> _retryAfterHallucination({
    required ChatSessionDeps deps,
    required int nextRetry,
  }) async {
    final hook = deps.hook;
    if (hook == null) return;
    await deps.messages.saveMessage(_userMessage(hook.hallucinationCorrection));
    await _runPipeline(deps, hallucinationRetry: nextRetry);
  }

  Future<void> _autoTitleIfNeeded(
    ChatSessionDeps deps,
    String assistantResponse,
  ) async {
    final conversation = await deps.conversations.getConversation(
      conversationId,
    );
    if (conversation == null) return;
    if (conversation.title != kDefaultConversationTitle) return;

    final title = _logic.generateAutoTitle(assistantResponse);
    if (title != null) {
      await deps.conversations.renameConversation(conversationId, title);
    }
  }

  /// After a cancel or a transport error: keep the partial text if there is
  /// any, otherwise drop the empty placeholder. Tool calls cut mid-stream
  /// are removed first so the row never carries unparseable arguments.
  Future<void> _cleanupAfterInterruption() async {
    final persister = _persister!;
    _stopwatch.stop();
    _accumulator.dropIncompleteToolCalls();
    if (_accumulator.isSendable) {
      await persister.commitPartial();
    } else {
      await persister.discard();
    }
  }
}
