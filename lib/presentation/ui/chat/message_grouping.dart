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
