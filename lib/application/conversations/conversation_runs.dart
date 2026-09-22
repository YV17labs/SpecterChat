import '../../domain/models/message.dart';

/// What answered one user message: the assistant turns and the tool calls
/// up to the next one. [user] is `null` for a history that does not start
/// with a user message.
typedef ConversationRun = ({Message? user, List<Message> answers});

/// [messages] (in order) split into runs. The one place that decides where
/// a run starts — the export's totals and the Σ under a reply must agree.
List<ConversationRun> runsOf(Iterable<Message> messages) {
  final runs = <ConversationRun>[];
  for (final message in messages) {
    if (message.role == MessageRole.user) {
      runs.add((user: message, answers: []));
    } else if (message.role != MessageRole.system) {
      if (runs.isEmpty) runs.add((user: null, answers: []));
      runs.last.answers.add(message);
    }
  }
  return runs;
}

/// What some assistant turns weighed and how long they took. Tool
/// messages are not in it: their time is not generation time.
typedef RunTotals = ({int promptTokens, int completionTokens, int durationMs});

/// Nothing measured.
const RunTotals noTotals = (
  promptTokens: 0,
  completionTokens: 0,
  durationMs: 0,
);

extension RunTotalsX on RunTotals {
  /// What it weighed in all, sent and received together.
  int get tokens => promptTokens + completionTokens;

  /// The two added up.
  RunTotals plus(RunTotals other) => (
    promptTokens: promptTokens + other.promptTokens,
    completionTokens: completionTokens + other.completionTokens,
    durationMs: durationMs + other.durationMs,
  );
}

/// What the assistant turns among [messages] cost — the one place these
/// sums are written, so the export's totals and the Σ under a reply are
/// the same arithmetic and not two copies of it.
///
/// [RunTotals.promptTokens] adds up what every turn was sent, so a tool
/// loop counts the context it resent each time: that is what the run
/// actually cost, not what its last request carried.
RunTotals totalsOf(Iterable<Message> messages) =>
    messages.fold(noTotals, (totals, message) => totals.plus(_turn(message)));

/// What one message weighed; nothing at all unless it is an assistant
/// turn.
RunTotals _turn(Message message) => message.role == MessageRole.assistant
    ? (
        promptTokens: message.promptTokens ?? 0,
        completionTokens: message.completionTokens,
        durationMs: message.durationMs,
      )
    : noTotals;

/// Running [totalsOf] keyed by assistant message id — the Σ shown under a
/// reply, stopped at each turn. User and tool messages have no entry.
///
/// Runs come from [runsOf], the split the export writes too.
Map<String, RunTotals> cumulativeRunTotals(Iterable<Message> messages) {
  final totals = <String, RunTotals>{};
  for (final run in runsOf(messages)) {
    var running = noTotals;
    for (final message in run.answers) {
      if (message.role != MessageRole.assistant) continue;
      running = running.plus(_turn(message));
      totals[message.id] = running;
    }
  }
  return totals;
}
