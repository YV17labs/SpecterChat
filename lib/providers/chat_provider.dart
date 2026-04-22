import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_session_manager.dart';
import '../domain/chat_session.dart';
import '../domain/chat_session_deps.dart';
import 'attachment_provider.dart';
import 'conversation_provider.dart';
import 'effective_settings_provider.dart';
import 'llm_provider.dart';
import 'mcp_provider.dart';
import 'settings_provider.dart';

/// Singleton registry of streaming chat sessions. One instance for the
/// whole app — created lazily, disposed only on app shutdown.
///
/// The resolver closure is invoked every time a session needs a fresh
/// deps snapshot (top-level send, tool-call continuation, retry). It
/// reads the currently active settings and services via `ref.read`, so
/// each send captures the state the user sees at that moment.
final chatSessionManagerProvider = Provider<ChatSessionManager>((ref) {
  final manager = ChatSessionManager(
    resolveDeps: () => ChatSessionDeps(
      llm: ref.read(llmServiceProvider),
      mcpService: ref.read(mcpServiceProvider),
      repo: ref.read(conversationRepositoryProvider),
      attachments: ref.read(attachmentRepositoryProvider),
      mcpTools: ref.read(mcpToolsProvider),
      mcpServers: ref.read(settingsProvider).mcpServers,
      settings: ref.read(settingsProvider),
      effectiveSystemPrompt:
          ref.read(effectiveSettingsProvider).systemPrompt,
      mcpInstructions: ref.read(mcpInstructionsProvider),
    ),
  );
  ref.onDispose(() {
    // Fire-and-forget: Riverpod dispose can't be async.
    manager.disposeAll();
  });
  return manager;
});

/// Per-conversation session handle. Returns the same [ChatSession]
/// reference for the lifetime of the session in the manager — the
/// widget then listens to `session.state` via [ValueListenableBuilder]
/// for reactive lifecycle updates, and reads actual message content
/// from `conversationMessagesProvider.family` (which watches Drift).
///
/// The provider's `ref.onDispose` releases an observer slot on the
/// manager so LRU eviction can reclaim the session if no widget is
/// watching it. While at least one widget watches, the session is
/// pinned — its [ValueNotifier] cannot be torn down under the UI.
final chatSessionProvider = Provider.autoDispose.family<ChatSession, String>(
  (ref, conversationId) {
    final manager = ref.watch(chatSessionManagerProvider);
    final session = manager.getOrCreate(conversationId);
    manager.acquire(conversationId);
    ref.onDispose(() => manager.release(conversationId));
    return session;
  },
);
