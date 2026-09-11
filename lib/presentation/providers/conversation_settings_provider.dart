import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/conversation_settings.dart';
import 'conversation_provider.dart';

/// Optimistic view of one conversation's settings overrides.
///
/// Slider drags fire many updates per second; each is reflected here
/// immediately (so the UI tracks the drag) and handed to
/// `ConversationActions.updateSettings`, which owns the debounced write.
/// `null` means "nothing edited yet — render from the persisted
/// conversation".
final conversationSettingsProvider = NotifierProvider.autoDispose
    .family<ConversationSettingsNotifier, ConversationSettings?, String>(
      ConversationSettingsNotifier.new,
    );

class ConversationSettingsNotifier extends Notifier<ConversationSettings?> {
  ConversationSettingsNotifier(this.conversationId);

  final String conversationId;

  @override
  ConversationSettings? build() => null;

  /// Apply [change] on top of the pending override, or the persisted
  /// settings when nothing is pending yet.
  void update(ConversationSettings Function(ConversationSettings) change) {
    final persisted = ref.read(conversationByIdProvider(conversationId));
    final current =
        state ?? persisted?.settings ?? const ConversationSettings();
    final updated = change(current);
    // Slider drags can fire at the same rounded value repeatedly.
    if (updated == state) return;
    state = updated;
    ref
        .read(conversationActionsProvider)
        .updateSettings(conversationId, updated);
  }
}
