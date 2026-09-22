import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/conversations/conversation_actions.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/message.dart';
import 'chat_input_provider.dart';
import 'chat_provider.dart';
import 'conversation_export_provider.dart';
import 'database_provider.dart';
import 'settings_provider.dart';

/// How many messages the UI keeps in memory by default for the active
/// conversation. Older messages still live in the database and the LLM
/// pipeline sees the full history — the cap only bounds the live widget
/// tree so very long conversations don't balloon RAM.
const int kDefaultMessageWindowSize = 200;

/// Upper bound for the view window. The UI can expand the window (load
/// older messages), but we stop at this cap to prevent a runaway expansion
/// from defeating the whole memory-bounding strategy.
const int kMaxMessageWindowSize = 2000;

final conversationActionsProvider = Provider<ConversationActions>((ref) {
  final actions = ConversationActions(
    conversations: ref.watch(conversationRepositoryProvider),
    sessions: ref.watch(chatSessionManagerProvider),
  );
  // Riverpod dispose can't be async; the write is fire-and-forget.
  ref.onDispose(() => actions.flushPendingSettings().ignore());
  return actions;
});

final conversationListProvider = StreamProvider<List<Conversation>>((ref) {
  return ref.watch(conversationRepositoryProvider).watchAllConversations();
});

/// Selected conversation id plus every action that changes the selection
/// as a side effect (create, fork, delete). UI code never pairs a
/// repository call with a `select` by hand.
final conversationControllerProvider =
    NotifierProvider<ConversationController, String?>(
      ConversationController.new,
    );

class ConversationController extends Notifier<String?> {
  @override
  String? build() => null;

  ConversationActions get _actions => ref.read(conversationActionsProvider);

  void select(String? id) => state = id;

  /// New empty conversation, selected.
  Future<void> createNew() async {
    final prompt = ref.read(settingsProvider).defaultSystemPrompt;
    state = await _actions.createNew(defaultSystemPrompt: prompt);
  }

  /// New conversation inheriting [sourceId]'s prompt and settings,
  /// selected. With [draft], the text is dropped into the input box so
  /// the user can tweak it before sending.
  Future<void> fork(String sourceId, {String? draft}) async {
    state = await _actions.fork(sourceId);
    if (draft != null) {
      ref.read(chatInputInjectionProvider.notifier).inject(draft);
    }
  }

  Future<void> rename(String id, String title) => _actions.rename(id, title);

  /// Asks where to save [id]'s JSON export — every message, what each turn
  /// was generated with and measured at — then writes it. `false` when
  /// the user cancelled.
  Future<bool> export(String id) => ref
      .read(conversationExporterProvider)
      .export(id, settings: ref.read(settingsProvider));

  Future<void> delete(String id) async {
    if (state == id) state = null;
    await _actions.delete(id);
  }
}

/// A conversation from the live list, or `null` while loading / deleted.
final conversationByIdProvider = Provider.family<Conversation?, String>((
  ref,
  id,
) {
  return ref
      .watch(conversationListProvider)
      .whenOrNull(
        data: (conversations) =>
            conversations.where((c) => c.id == id).firstOrNull,
      );
});

final selectedConversationProvider = Provider<Conversation?>((ref) {
  final id = ref.watch(conversationControllerProvider);
  return id == null ? null : ref.watch(conversationByIdProvider(id));
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
}

final messageWindowSizeProvider = NotifierProvider.autoDispose
    .family<MessageWindowNotifier, int, String>((_) => MessageWindowNotifier());

/// Stream of the most recent messages for a conversation, bounded by the
/// view window. `autoDispose` is critical: switching conversations must
/// free the previous list (which can be hundreds of messages with images).
final conversationMessagesProvider = StreamProvider.autoDispose
    .family<List<Message>, String>((ref, conversationId) {
      final repo = ref.watch(messageRepositoryProvider);
      final windowSize = ref.watch(messageWindowSizeProvider(conversationId));
      return repo.watchMessages(conversationId, limit: windowSize);
    });

/// Total persisted message count for a conversation.
final conversationMessageCountProvider = StreamProvider.autoDispose
    .family<int, String>((ref, conversationId) {
      return ref
          .watch(messageRepositoryProvider)
          .watchMessageCount(conversationId);
    });
