import 'dart:async';

import '../../domain/models/conversation_settings.dart';
import '../../domain/repositories/i_conversation_repository.dart';
import '../chat/chat_session_manager.dart';

/// Use cases that touch a conversation as a whole. Every UI entry point
/// (sidebar, fork button, delete menu) routes through here so the rules —
/// what a new conversation inherits, what a delete must tear down — live
/// in exactly one place.
class ConversationActions {
  ConversationActions({
    required IConversationRepository conversations,
    required ChatSessionManager sessions,
    this.settingsWriteDebounce = const Duration(milliseconds: 500),
  }) : _conversations = conversations,
       _sessions = sessions;

  final IConversationRepository _conversations;
  final ChatSessionManager _sessions;

  /// How long to coalesce successive [updateSettings] calls for one
  /// conversation before writing. Sliders fire many times per second.
  final Duration settingsWriteDebounce;
  final Map<String, _PendingSettings> _pendingSettings = {};

  /// Create an empty conversation. An empty [defaultSystemPrompt] means
  /// "inherit the global prompt at send time" rather than pinning ''.
  Future<String> createNew({required String defaultSystemPrompt}) {
    return _conversations.createConversation(
      systemPrompt: defaultSystemPrompt.isNotEmpty ? defaultSystemPrompt : null,
    );
  }

  /// Create a conversation that inherits [sourceId]'s system prompt and
  /// per-conversation settings, but none of its messages. Falls back to a
  /// blank conversation if the source has meanwhile been deleted.
  Future<String> fork(String sourceId) async {
    final source = await _conversations.getConversation(sourceId);
    return _conversations.createConversation(
      systemPrompt: source?.systemPrompt,
      settings: source?.settings,
    );
  }

  Future<void> rename(String id, String title) {
    return _conversations.renameConversation(id, title);
  }

  /// Tear down the streaming session first so a stream still in flight
  /// cannot write to rows that are about to disappear.
  Future<void> delete(String id) async {
    _pendingSettings.remove(id)?.timer.cancel();
    await _sessions.disposeSession(id);
    await _conversations.deleteConversation(id);
  }

  /// Schedule [settings] to be written after [settingsWriteDebounce];
  /// a later call for the same conversation replaces the pending value and
  /// restarts the timer. Nothing is ever dropped: [flushPendingSettings]
  /// runs on shutdown.
  void updateSettings(String id, ConversationSettings settings) {
    _pendingSettings.remove(id)?.timer.cancel();
    _pendingSettings[id] = _PendingSettings(
      settings,
      Timer(settingsWriteDebounce, () => _writeSettings(id)),
    );
  }

  /// Write every pending settings edit now.
  Future<void> flushPendingSettings() async {
    for (final id in _pendingSettings.keys.toList()) {
      _pendingSettings[id]!.timer.cancel();
      await _writeSettings(id);
    }
  }

  Future<void> _writeSettings(String id) async {
    final pending = _pendingSettings.remove(id);
    if (pending == null) return;
    await _conversations.updateConversationSettings(id, pending.settings);
  }
}

class _PendingSettings {
  final ConversationSettings settings;
  final Timer timer;
  const _PendingSettings(this.settings, this.timer);
}
