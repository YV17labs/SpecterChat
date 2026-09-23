import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../core/id_gen.dart';
import '../../domain/chat_session_state.dart';
import '../../domain/models/app_settings.dart' show McpToolInfo;
import '../../domain/models/conversation.dart';
import '../../domain/models/message.dart';
import '../../domain/models/message_stats.dart';
import '../../domain/models/photo_metadata.dart';
import '../../domain/models/request_context.dart';
import '../../domain/models/request_profile.dart';
import '../../domain/services/cancellation_token.dart';
import '../../domain/services/i_llm_service.dart';
import '../images/stored_photo_metadata.dart';
import '../mcp/active_mcp_server.dart';
import 'chat_logic.dart';
import 'chat_session_deps.dart';
import 'context_budget.dart';
import 'generation_recorder.dart';
import 'message_writes.dart';
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
///           │   watches the messages table) sees content grow live, and
///           │   a [GenerationRecorder] measures it for the row's stats
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
  ///
  /// [images] are attached to the user message (one image block each, with
  /// its photo metadata) and forwarded to the model as `image_url` parts.
  /// An empty [userText] is allowed when at least one image is given.
  Future<void> sendMessage(
    String userText, {
    List<DescribedImage> images = const [],
  }) async {
    if (_disposed) return;
    if (isGenerating) {
      _log.warning('sendMessage ignored — session already streaming');
      return;
    }
    if (userText.trim().isEmpty && images.isEmpty) return;
    lastActivity = DateTime.now();
    final deps = _resolveDeps();
    state.value = state.value.toStreaming('');
    _inFlight = _send(userText, images, deps);
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

  Future<void> _send(
    String userText,
    List<DescribedImage> images,
    ChatSessionDeps deps,
  ) async {
    try {
      await _saveUserMessage(deps, userText, images);
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

  /// Persist the user turn: the row and its attachment blobs (images and
  /// their photo metadata) in one transaction, like every other message
  /// with images.
  Future<void> _saveUserMessage(
    ChatSessionDeps deps,
    String text,
    List<DescribedImage> images,
  ) async {
    final write = _logic.buildUserMessage(
      id: generateId(),
      conversationId: conversationId,
      text: text,
      images: images,
    );
    await saveMessagesWithAttachments(deps.messages, deps.attachments, [write]);
    // The bytes are needed for the request we are about to build; keep
    // them so the pipeline does not re-read what it just wrote.
    final blobs = {for (final a in write.attachments) a.attachmentId: a};
    for (final id in write.message.imageAttachmentIds()) {
      final image = blobs[id]!;
      _imageBytes[id] = (bytes: image.bytes, mimeType: image.mimeType);
    }
  }

  /// Pipeline entry. Rebuilds the history from the DB, then streams one
  /// LLM response. Recurses for tool-call continuations.
  Future<void> _runPipeline(
    ChatSessionDeps deps, {
    int hallucinationRetry = 0,
  }) async {
    if (_isCancelled) return;
    final stored = await deps.messages.getMessages(conversationId);
    final trimmed = trimHistory(stored, deps.budget);
    final history = trimmed.history;
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
      trim: trimmed,
      hallucinationRetry: hallucinationRetry,
    );
  }

  Future<void> _streamResponse({
    required ChatSessionDeps deps,
    required List<Message> history,
    required HistoryTrim trim,
    required int hallucinationRetry,
  }) async {
    _accumulator.reset();
    final messageId = generateId();
    final tools = enabledToolsOf(deps.activeServers);
    final recorder = GenerationRecorder(
      model: deps.llm.model,
      endpoint: deps.llm.endpoint,
      profile: deps.profile,
      requestContextId: await _storeRequestContext(deps, tools),
      retry: hallucinationRetry,
      droppedRuns: trim.droppedRuns,
      droppedImages: trim.droppedImages,
    );
    final persister = _persister = StreamingPersister(
      messageId: messageId,
      conversationId: conversationId,
      accumulator: _accumulator,
      recorder: recorder,
      messages: deps.messages,
      logic: _logic,
      interval: _persistenceInterval,
    );
    // The photo metadata an image of this turn inherits, copied once for
    // the turn: bound to the placeholder, it lives and dies with it (the
    // source's message may go, a discarded placeholder takes it along).
    Future<PhotoMetadataRef>? inherited;

    // Publish the streaming id so the UI can flag the live message.
    state.value = state.value.toStreaming(messageId);

    // Create the placeholder row immediately — the UI shows a typing
    // indicator as soon as the user sends.
    await persister.flush(force: true);
    persister.start();

    final events = deps.llm.streamChatCompletion(
      history: history,
      systemPrompt: deps.mergedSystemPrompt,
      profile: deps.profile,
      imageBytes: _imageBytes,
      tools: tools,
      cancellationToken: _cancellation,
    );

    await for (final event in events) {
      lastActivity = DateTime.now();
      recorder.record(event);
      switch (event) {
        case ContentDelta(:final text):
          _accumulator.addContent(text);
        case ThinkingDelta(:final text):
          _accumulator.addThinking(text);
        case ToolCallDelta():
          if (_accumulator.addToolCallDelta(event)) {
            await persister.flush(force: true);
          }
        case ProgressDelta(:final progress):
          state.value = state.value.withProgress(progress);
        case ImageDelta(:final bytes, :final mimeType, :final textToImage):
          final (:origin, :metadata) = _logic.generatedImageOrigin(
            history,
            textToImage: textToImage,
          );
          // Stored before any block references it, like the image bytes.
          final inheritedCopy = metadata == null
              ? null
              : await (inherited ??= copyPhotoMetadata(
                  deps.attachments,
                  metadata,
                  attachmentId: generateId(),
                  messageId: messageId,
                ));
          await _storeStreamedImage(
            deps: deps,
            messageId: messageId,
            bytes: bytes,
            mimeType: mimeType,
            origin: origin,
            metadata: inheritedCopy,
          );
          // Show the image as soon as it lands rather than on the next
          // throttle tick — it is the whole point of the turn.
          await persister.flush(force: true);
        case StreamUsage(:final promptTokens, completionTokens: final ct):
          state.value = SessionStreaming(
            streamingMessageId: messageId,
            promptTokens: promptTokens,
            completionTokens: ct,
            progress: state.value.progress,
          );
        case ServerReport():
          break;
        case StreamDone():
          await _handleStreamDone(
            deps: deps,
            hallucinationRetry: hallucinationRetry,
          );
          return;
        case StreamCancelled():
          await _cleanupAfterInterruption(GenerationOutcome.cancelled);
          return;
        case StreamError(:final message):
          await _cleanupAfterInterruption(
            GenerationOutcome.failed,
            error: message,
          );
          state.value = state.value.toError(message);
          return;
      }
    }

    // Stream ended without a terminal event (rare) — treat as completion.
    await _handleStreamDone(deps: deps, hallucinationRetry: hallucinationRetry);
  }

  Future<void> _handleStreamDone({
    required ChatSessionDeps deps,
    required int hallucinationRetry,
  }) async {
    final persister = _persister!;
    final analysis = _logic.analyzeCompletion(_accumulator, hook: deps.hook);

    if (analysis.keepMessage) {
      await persister.commit();
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

  /// The id of what this request carries besides its messages — the system
  /// prompt as sent and the tool definitions. Stored under its content's
  /// fingerprint, so a turn that carries the same one references the same
  /// row. `null` for an image model, sent neither.
  Future<String?> _storeRequestContext(
    ChatSessionDeps deps,
    List<McpToolInfo> tools,
  ) {
    if (deps.profile is ImageRequestProfile) return Future.value();
    return deps.conversations.saveRequestContext(
      conversationId,
      RequestContext(
        systemPrompt: deps.mergedSystemPrompt,
        tools: [for (final t in tools) t.copyWith(icons: const [])],
      ),
    );
  }

  /// Write a streamed image's bytes to the attachments table (bound to the
  /// placeholder row, which already exists) and reference it from the
  /// accumulator, with how the model made it ([origin]) and the photo
  /// [metadata] it inherits, already stored. Bytes go first so the next
  /// upsert never points at an id the watcher cannot resolve.
  Future<void> _storeStreamedImage({
    required ChatSessionDeps deps,
    required String messageId,
    required Uint8List bytes,
    required String mimeType,
    required AiOrigin origin,
    required PhotoMetadataRef? metadata,
  }) async {
    final attachmentId = generateId();
    await deps.attachments.storeBytes(
      attachmentId: attachmentId,
      messageId: messageId,
      bytes: bytes,
      mimeType: mimeType,
    );
    _accumulator.addImage(
      ImageContentBlock(
        attachmentId: attachmentId,
        mimeType: mimeType,
        byteSize: bytes.length,
        photoMetadata: metadata,
        aiOrigin: origin,
      ),
    );
    // The model may be asked to edit its own output on the next turn.
    _imageBytes[attachmentId] = (bytes: bytes, mimeType: mimeType);
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
    await deps.messages.saveMessage(
      _logic
          .buildUserMessage(
            id: generateId(),
            conversationId: conversationId,
            text: hook.hallucinationCorrection,
          )
          .message,
    );
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
  /// any, with how the turn ended, otherwise drop the empty placeholder.
  /// Tool calls cut mid-stream are removed first so the row never carries
  /// unparseable arguments.
  Future<void> _cleanupAfterInterruption(
    GenerationOutcome outcome, {
    String? error,
  }) async {
    final persister = _persister!;
    _accumulator.dropIncompleteToolCalls();
    if (_accumulator.isSendable) {
      await persister.commitPartial(outcome, error: error);
    } else {
      await persister.discard();
    }
  }
}
