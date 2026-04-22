import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../database/conversation_repository.dart';
import '../database/i_conversation_repository.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import 'database_provider.dart';

final _log = Logger('ConversationProvider');

/// How many messages the UI keeps in memory by default for the active
/// conversation. Older messages still live in the database and the LLM
/// pipeline sees the full history — the cap only bounds the live widget
/// tree so very long conversations don't balloon RAM.
const int kDefaultMessageWindowSize = 200;

/// Upper bound for the view window. The UI can expand the window (load
/// older messages), but we stop at this cap to prevent a runaway expansion
/// from defeating the whole memory-bounding strategy.
const int kMaxMessageWindowSize = 2000;

final conversationRepositoryProvider =
    Provider<IConversationRepository>((ref) {
  final database = ref.watch(databaseProvider);
  return ConversationRepository(database);
});

final conversationListProvider =
    StreamProvider<List<Conversation>>((ref) {
  final repo = ref.watch(conversationRepositoryProvider);
  return repo.watchAllConversations();
});

final selectedConversationIdProvider =
    NotifierProvider<SelectedConversationIdNotifier, String?>(
        SelectedConversationIdNotifier.new);

class SelectedConversationIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedConversationProvider = Provider<Conversation?>((ref) {
  final id = ref.watch(selectedConversationIdProvider);
  if (id == null) return null;

  final listAsync = ref.watch(conversationListProvider);
  return listAsync.whenOrNull(
    data: (conversations) {
      try {
        return conversations.firstWhere((c) => c.id == id);
      } catch (_) {
        _log.fine('Selected conversation $id no longer in list');
        return null;
      }
    },
  );
});

/// Per-conversation view-window size. Auto-disposed so switching away
/// from a conversation frees the state — on next view the window resets
/// to [kDefaultMessageWindowSize].
class MessageWindowNotifier extends Notifier<int> {
  @override
  int build() => kDefaultMessageWindowSize;

  /// Expand the window by [step], clamped to [kMaxMessageWindowSize] so
  /// "load more" can never defeat the memory bound.
  void expand({int step = kDefaultMessageWindowSize}) {
    final next = state + step;
    state = next > kMaxMessageWindowSize ? kMaxMessageWindowSize : next;
  }

  bool get isAtCap => state >= kMaxMessageWindowSize;
}

final messageWindowSizeProvider = NotifierProvider.autoDispose
    .family<MessageWindowNotifier, int, String>(
  (_) => MessageWindowNotifier(),
);

/// Stream of the most recent messages for a conversation, bounded by the
/// view window. `autoDispose` is critical: switching conversations must
/// free the previous list (which can be hundreds of messages with images).
final conversationMessagesProvider = StreamProvider.autoDispose
    .family<List<Message>, String>((ref, conversationId) {
  final repo = ref.watch(conversationRepositoryProvider);
  final windowSize = ref.watch(messageWindowSizeProvider(conversationId));
  return repo.watchMessages(conversationId, limit: windowSize);
});

/// Total persisted message count for a conversation. Streamed directly
/// from Drift with `distinct()` so it only emits on actual count changes,
/// not on every streaming-partial upsert.
final conversationMessageCountProvider = StreamProvider.autoDispose
    .family<int, String>((ref, conversationId) {
  final repo = ref.watch(conversationRepositoryProvider);
  return repo.watchMessageCount(conversationId);
});
