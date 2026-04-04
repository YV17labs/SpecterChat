import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../database/conversation_repository.dart';
import '../database/i_conversation_repository.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import 'database_provider.dart';

final _log = Logger('ConversationProvider');

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

final conversationMessagesProvider =
    StreamProvider.family<List<Message>, String>(
        (ref, conversationId) {
  final repo = ref.watch(conversationRepositoryProvider);
  return repo.watchMessages(conversationId);
});
