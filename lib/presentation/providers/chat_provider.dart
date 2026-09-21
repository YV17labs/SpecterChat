import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/chat/chat_session.dart';
import '../../application/chat/chat_session_deps.dart';
import '../../application/chat/chat_session_manager.dart';
import '../../application/llm_hooks/llm_hook_registry.dart';
import 'database_provider.dart';
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
      conversations: ref.read(conversationRepositoryProvider),
      messages: ref.read(messageRepositoryProvider),
      attachments: ref.read(attachmentRepositoryProvider),
      activeServers: ref.read(activeMcpServersProvider),
      modelName: ref.read(settingsProvider).api.selectedModel,
      effectiveSystemPrompt: ref.read(effectiveSettingsProvider).systemPrompt,
      profile: ref.read(requestProfileProvider),
      hooks: defaultLlmHookRegistry,
    ),
  );
  // Fire-and-forget: Riverpod dispose can't be async.
  ref.onDispose(() => manager.disposeAll().ignore());
  return manager;
});

/// Per-conversation session handle. Returns the same [ChatSession]
/// reference for the lifetime of the session in the manager — the
/// widget then listens to `session.state` via `ValueListenableBuilder`
/// for reactive lifecycle updates, and reads actual message content
/// from `conversationMessagesProvider` (which watches the database).
///
/// The provider's `ref.onDispose` releases an observer slot on the
/// manager so LRU eviction can reclaim the session if no widget is
/// watching it. While at least one widget watches, the session is
/// pinned — its `ValueNotifier` cannot be torn down under the UI.
final chatSessionProvider = Provider.autoDispose.family<ChatSession, String>((
  ref,
  conversationId,
) {
  final manager = ref.watch(chatSessionManagerProvider);
  final session = manager.getOrCreate(conversationId);
  manager.acquire(conversationId);
  ref.onDispose(() => manager.release(conversationId));
  return session;
});
