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

/// Cumulative assistant duration (ms) since the last user message,
/// inclusive of each assistant message's own duration. Keyed by message
/// id; user and tool messages have no entry.
Map<String, int> cumulativeDurations(List<Message> messages) {
  final result = <String, int>{};
  var running = 0;
  for (final msg in messages) {
    if (msg.role == MessageRole.user) {
      running = 0;
    } else if (msg.role == MessageRole.assistant) {
      running += msg.durationMs;
      result[msg.id] = running;
    }
  }
  return result;
}
