import 'dart:async';

import 'package:logging/logging.dart';

import '../../domain/models/message.dart';
import '../../domain/repositories/i_message_repository.dart';
import 'chat_logic.dart';
import 'stream_accumulator.dart';

final _log = Logger('StreamingPersister');

/// Writes one streaming assistant turn to the messages table.
///
/// Created per turn, together with the placeholder row it manages:
///
///   1. [flush] upserts the placeholder with whatever the accumulator
///      holds — called on a periodic timer while the stream runs, and
///      immediately when something the user should see right away lands
///      (the first fragment of a tool call).
///   2. [commit] writes the final content and flips `is_streaming` off.
///   3. [discard] deletes the row when the turn produced nothing.
///
/// The session never touches timers or the repository for partial
/// content; it only decides which of the three endings applies.
class StreamingPersister {
  StreamingPersister({
    required this.messageId,
    required this.conversationId,
    required StreamAccumulator accumulator,
    required IMessageRepository messages,
    required ChatLogic logic,
    required Duration interval,
  }) : _accumulator = accumulator,
       _messages = messages,
       _logic = logic,
       _interval = interval;

  final String messageId;
  final String conversationId;
  final StreamAccumulator _accumulator;
  final IMessageRepository _messages;
  final ChatLogic _logic;
  final Duration _interval;

  Timer? _timer;

  /// Start the periodic flush. Idempotent.
  void start() {
    _timer ??= Timer.periodic(_interval, (_) => flush().ignore());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Persist the current buffers if they changed since the last flush
  /// (always when [force] is set). Failures are logged, not thrown — a
  /// missed partial write costs nothing, the next flush catches up.
  Future<void> flush({bool force = false}) async {
    if (!_accumulator.shouldPersist(force: force)) return;
    try {
      await _messages.upsertStreamingMessage(_snapshot(isStreaming: true));
    } catch (e, st) {
      _log.warning('Partial persist failed', e, st);
    }
  }

  /// Write the finished turn (same id, `is_streaming = 0`, token and
  /// duration info) on top of the placeholder.
  Future<void> commit({
    required int completionTokens,
    required int durationMs,
  }) {
    stop();
    return _finalize(
      _snapshot(
        isStreaming: false,
        completionTokens: completionTokens,
        durationMs: durationMs,
      ),
    );
  }

  /// Keep whatever partial content exists and mark the row finished.
  /// Used after a cancel so the user still sees what arrived.
  Future<void> commitPartial() async {
    stop();
    try {
      await _finalize(_snapshot(isStreaming: false));
    } catch (e, st) {
      _log.fine('finalize after interruption failed', e, st);
    }
  }

  /// Last upsert + `is_streaming` flip in one transaction, so watchers see
  /// a single change instead of two.
  Future<void> _finalize(Message message) {
    return _messages.runInTransaction(() async {
      await _messages.upsertStreamingMessage(message);
      await _messages.finalizeStreamingMessage(messageId);
    });
  }

  Message _snapshot({
    required bool isStreaming,
    int completionTokens = 0,
    int durationMs = 0,
  }) => _logic.buildAssistantMessage(
    id: messageId,
    conversationId: conversationId,
    content: _accumulator.content.toString(),
    thinking: _accumulator.thinking.toString(),
    toolCalls: _accumulator.toolCalls,
    isStreaming: isStreaming,
    completionTokens: completionTokens,
    durationMs: durationMs,
  );

  /// Remove the placeholder row.
  Future<void> discard() async {
    stop();
    try {
      await _messages.deleteMessage(messageId);
    } catch (e, st) {
      _log.fine('discard placeholder failed', e, st);
    }
  }
}
