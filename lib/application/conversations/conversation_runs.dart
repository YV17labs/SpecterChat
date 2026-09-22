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
