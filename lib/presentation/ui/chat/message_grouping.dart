import '../../../application/conversations/conversation_runs.dart';
import '../../../domain/models/message.dart';

/// Group each tool-result message with the assistant message that called
/// it, so a bubble can render the call and its result together.
///
/// UUIDv7 ids guarantee the list is in insertion order, so tool messages
/// always follow their owning assistant — simple adjacency suffices.
List<List<Message>> groupMessages(List<Message> messages) {
  final groups = <List<Message>>[];
  for (final msg in messages) {
    if (msg.role == MessageRole.tool && groups.isNotEmpty) {
      groups.last.add(msg);
    } else {
      groups.add([msg]);
    }
  }
  return groups;
}

/// Cumulative assistant duration (ms) within each run, inclusive of each
/// assistant message's own duration. Keyed by message id; user and tool
/// messages have no entry. The same sum the export writes as a run's
/// `generationMs`.
Map<String, int> cumulativeDurations(List<Message> messages) {
  final result = <String, int>{};
  for (final run in runsOf(messages)) {
    var running = 0;
    for (final msg in run.answers) {
      if (msg.role != MessageRole.assistant) continue;
      running += msg.durationMs;
      result[msg.id] = running;
    }
  }
  return result;
}
