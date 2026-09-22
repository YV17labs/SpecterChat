import '../../domain/models/message_stats.dart';
import '../../domain/models/request_profile.dart';
import '../../domain/services/i_llm_service.dart';

/// Measures one assistant turn while it streams, for the message's
/// [GenerationStats].
///
/// Started when the request is sent and fed every [StreamEvent] the turn
/// receives. [snapshot] is what the row carries while the stream runs —
/// outcome `interrupted`, which is what stays if the app never gets to
/// finish it — and [finish] what the final row keeps.
class GenerationRecorder {
  GenerationRecorder({
    required String model,
    required String endpoint,
    required RequestProfile profile,
    String? requestContextId,
    int retry = 0,
    DateTime Function() now = DateTime.now,
    int Function()? elapsedMs,
  }) : _base = GenerationStats(
         model: model,
         endpoint: endpoint,
         generation: profile.generation,
         image: profile.image,
         requestContextId: requestContextId,
         retry: retry,
         startedAt: now().toUtc(),
         durationMs: 0,
         outcome: GenerationOutcome.interrupted,
       ),
       _elapsedMs = elapsedMs ?? _startStopwatch();

  final GenerationStats _base;
  final int Function() _elapsedMs;

  static int Function() _startStopwatch() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }

  int? _firstTokenMs;
  int? _firstAnswerMs;
  int _fragments = 0;
  int? _promptTokens;
  int? _completionTokens;
  final Map<String, dynamic> _server = {};
  GenerationStats? _finished;

  /// Take [event] into account. Events after [finish] are ignored.
  void record(StreamEvent event) {
    if (_finished != null) return;
    switch (event) {
      case ThinkingDelta():
        _output(answer: false);
      case ContentDelta() || ToolCallDelta() || ImageDelta():
        _output(answer: true);
      case StreamUsage(:final promptTokens, :final completionTokens):
        _promptTokens = promptTokens;
        _completionTokens = completionTokens;
      case ServerReport(:final fields):
        _server.addAll(fields);
      case ProgressDelta() ||
          StreamDone() ||
          StreamCancelled() ||
          StreamError():
        break;
    }
  }

  void _output({required bool answer}) {
    final now = _elapsedMs();
    _fragments++;
    _firstTokenMs ??= now;
    if (answer) _firstAnswerMs ??= now;
  }

  /// The turn as measured so far, not over yet.
  GenerationStats snapshot() => _finished ?? _stats(_elapsedMs());

  /// The turn is over: its final stats, the clock stopped. Later calls
  /// return the same value.
  GenerationStats finish(GenerationOutcome outcome, {String? error}) =>
      _finished ??= _stats(_elapsedMs(), outcome: outcome, error: error);

  GenerationStats _stats(
    int durationMs, {
    GenerationOutcome outcome = GenerationOutcome.interrupted,
    String? error,
  }) => _base.copyWith(
    durationMs: durationMs,
    firstTokenMs: _firstTokenMs,
    firstAnswerMs: _firstAnswerMs,
    fragments: _fragments,
    promptTokens: _promptTokens,
    completionTokens: _completionTokens,
    outcome: outcome,
    error: error,
    server: {..._server},
  );
}
