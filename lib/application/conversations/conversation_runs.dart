import '../../domain/models/message.dart';

/// What answered one user message: the assistant turns and the tool calls
/// up to the next one. [user] is `null` for a history that does not start
/// with a user message.
typedef ConversationRun = ({Message? user, List<Message> answers});

/// Where each run starts in [messages] — the one place that decides it.
///
/// A run opens on every user message, and on the first message of a
/// history that does not begin with one. System messages before it open
/// nothing. [runsOf] reads this as runs; the context budget reads it as
/// the boundaries it may cut on, since dropping anything less than a
/// whole run can separate a tool call from the result that answers it.
List<int> runStartsOf(List<Message> messages) {
  final starts = <int>[];
  for (var i = 0; i < messages.length; i++) {
    final role = messages[i].role;
    if (role == MessageRole.user) {
      starts.add(i);
    } else if (starts.isEmpty && role != MessageRole.system) {
      starts.add(i);
    }
  }
  return starts;
}

/// [messages] (in order) split into runs, on the boundaries
/// [runStartsOf] gives — the export's totals and the Σ under a reply
/// must agree.
List<ConversationRun> runsOf(Iterable<Message> messages) {
  final list = messages is List<Message> ? messages : messages.toList();
  final starts = runStartsOf(list);
  return [
    for (var k = 0; k < starts.length; k++)
      _runIn(
        list,
        starts[k],
        k + 1 < starts.length ? starts[k + 1] : list.length,
      ),
  ];
}

/// The run held in `[from, to)`. Its user message is the first one when
/// the run opens on it; system messages are not answers.
ConversationRun _runIn(List<Message> messages, int from, int to) {
  final opensOnUser = messages[from].role == MessageRole.user;
  return (
    user: opensOnUser ? messages[from] : null,
    answers: [
      for (var i = opensOnUser ? from + 1 : from; i < to; i++)
        if (messages[i].role != MessageRole.system) messages[i],
    ],
  );
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
