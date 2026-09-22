import 'dart:async';

import 'package:logging/logging.dart';

import '../../domain/models/message.dart';
import '../../domain/models/message_stats.dart';
import '../../domain/repositories/i_message_repository.dart';
import 'chat_logic.dart';
import 'generation_recorder.dart';
import 'stream_accumulator.dart';

final _log = Logger('StreamingPersister');

/// Writes one streaming assistant turn to the messages table.
///
/// Created per turn, together with the placeholder row it manages:
///
///   1. [flush] upserts the placeholder with whatever the accumulator
///      holds, and the recorder's measures so far — called on a periodic
///      timer while the stream runs, and immediately when something the
///      user should see right away lands (the first fragment of a tool
///      call).
///   2. [commit] writes the final content with the turn's final stats and
///      flips `is_streaming` off.
///   3. [discard] deletes the row when the turn produced nothing.
///
/// The session never touches timers or the repository for partial
/// content; it only decides which of the three endings applies.
class StreamingPersister {
  StreamingPersister({
    required this.messageId,
    required this.conversationId,
    required StreamAccumulator accumulator,
    required GenerationRecorder recorder,
    required IMessageRepository messages,
    required ChatLogic logic,
    required Duration interval,
  }) : _accumulator = accumulator,
       _recorder = recorder,
       _messages = messages,
       _logic = logic,
       _interval = interval;

  final String messageId;
  final String conversationId;
  final StreamAccumulator _accumulator;
  final GenerationRecorder _recorder;
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

  /// Write the finished turn (same id, `is_streaming = 0`, its final
  /// stats) on top of the placeholder.
  Future<void> commit() {
    stop();
    _recorder.finish(GenerationOutcome.completed);
    return _finalize(_snapshot(isStreaming: false));
  }

  /// Keep whatever partial content exists and mark the row finished, with
  /// how the turn ended ([outcome], [error]). Used after a cancel or an
  /// error so the user still sees what arrived.
  Future<void> commitPartial(GenerationOutcome outcome, {String? error}) async {
    stop();
    _recorder.finish(outcome, error: error);
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

  /// The row as it stands, with the recorder's stats: unfinished while
  /// streaming, final once [commit] or [commitPartial] closed them.
  Message _snapshot({required bool isStreaming}) =>
      _logic.buildAssistantMessage(
        id: messageId,
        conversationId: conversationId,
        content: _accumulator.content.toString(),
        thinking: _accumulator.thinking.toString(),
        toolCalls: _accumulator.toolCalls,
        images: _accumulator.images,
        isStreaming: isStreaming,
        stats: _recorder.snapshot(),
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
