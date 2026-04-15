import 'dart:async';

import 'package:logging/logging.dart';

import '../domain/chat_session.dart';
import '../domain/chat_session_deps.dart';

final _log = Logger('ChatSessionManager');

/// Long-lived registry of active [ChatSession]s, keyed by conversation id.
///
/// The manager is a singleton held by a Riverpod `Provider` that never
/// auto-disposes. Every chat operation in the app flows through it.
///
/// Lifecycle rules:
///
///   - A session is created on demand the first time a conversation
///     streams a message, or the first time the UI asks to observe it.
///   - A session survives conversation switches in the UI — switching
///     just means the UI watches a different session's state.
///   - A session is evicted when it has been idle (no activity) long
///     enough AND the number of resident sessions exceeds
///     [maxActiveSessions]. Sessions that are actively streaming are
///     never evicted.
///   - When the manager itself is disposed (app shutdown), every
///     session is disposed in turn.
class ChatSessionManager {
  ChatSessionManager({
    required ChatSessionDepsResolver resolveDeps,
    this.maxActiveSessions = 10,
  }) : _resolveDeps = resolveDeps;

  final ChatSessionDepsResolver _resolveDeps;
  final int maxActiveSessions;

  final Map<String, ChatSession> _sessions = {};
  // Riverpod provider watchers per session. Used by LRU to avoid
  // evicting a session that the UI is currently observing — otherwise
  // the ValueListenableBuilder would blow up on next rebuild.
  final Map<String, int> _observerCount = {};

  /// Snapshot of ids currently held in memory. Exposed for diagnostics
  /// and for tests that want to assert on eviction.
  Iterable<String> get activeConversationIds => _sessions.keys;
  int get sessionCount => _sessions.length;

  /// Get the session for [conversationId], materialising it if needed.
  /// The caller does not own the returned instance — the manager does.
  ChatSession getOrCreate(String conversationId) {
    final existing = _sessions[conversationId];
    if (existing != null) return existing;

    final session = ChatSession(
      conversationId: conversationId,
      resolveDeps: _resolveDeps,
    );
    _sessions[conversationId] = session;
    _log.fine('Created session $conversationId '
        '(${_sessions.length} active)');

    // Hydrate token counts from persisted conversation state so the
    // context gauge does not flash zero on first paint.
    _hydrate(session).ignore();

    _evictIfNeeded();
    return session;
  }

  /// Return the session if it already exists, or `null`. Does not
  /// create one. Used by read-only observers.
  ChatSession? peek(String conversationId) => _sessions[conversationId];

  /// Increment the observer count for [conversationId]. Called by the
  /// Riverpod provider when a widget starts watching. An observed
  /// session is never evicted by LRU, even if it is idle and over cap,
  /// so the UI's [ValueListenableBuilder] never holds a dangling
  /// reference.
  void acquire(String conversationId) {
    _observerCount.update(conversationId, (c) => c + 1, ifAbsent: () => 1);
  }

  /// Decrement the observer count for [conversationId]. Called when
  /// the Riverpod provider is auto-disposed. Once no observers remain,
  /// the session is a candidate for LRU eviction.
  void release(String conversationId) {
    final current = _observerCount[conversationId];
    if (current == null) return;
    if (current <= 1) {
      _observerCount.remove(conversationId);
    } else {
      _observerCount[conversationId] = current - 1;
    }
    _evictIfNeeded();
  }

  /// Start streaming a user message in the session for [conversationId].
  /// Creates the session if needed. Returns once the top-level send
  /// resolves (which may involve multiple tool-call rounds).
  Future<void> sendMessage(String conversationId, String userText) {
    final session = getOrCreate(conversationId);
    return session.sendMessage(userText);
  }

  /// Cancel any in-flight stream for [conversationId]. Partial content
  /// already persisted is kept.
  Future<void> stopSession(String conversationId) async {
    final session = _sessions[conversationId];
    if (session == null) return;
    await session.stop();
  }

  /// Dispose and remove a session from the registry. Typically only
  /// called when a conversation is deleted by the user.
  Future<void> disposeSession(String conversationId) async {
    final session = _sessions.remove(conversationId);
    if (session == null) return;
    await session.dispose();
    _log.fine('Disposed session $conversationId '
        '(${_sessions.length} active)');
  }

  /// Dispose every session. Called on app shutdown via Riverpod
  /// `ref.onDispose`.
  Future<void> disposeAll() async {
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final s in sessions) {
      await s.dispose();
    }
    _log.info('Disposed all sessions (${sessions.length})');
  }

  // ---------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------

  Future<void> _hydrate(ChatSession session) async {
    try {
      final deps = _resolveDeps();
      final conv = await deps.repo.getConversation(session.conversationId);
      if (conv != null) {
        await session.hydrate(conv);
      }
    } catch (e, st) {
      _log.fine('Hydrate failed for ${session.conversationId}', e, st);
    }
  }

  /// LRU eviction: when the cap is exceeded, drop the least recently
  /// active session that is both idle and not currently observed by
  /// any widget. Streaming sessions and observed sessions are immune —
  /// evicting either would tear down a [ValueNotifier] out from under
  /// a live listener.
  void _evictIfNeeded() {
    if (_sessions.length <= maxActiveSessions) return;

    final candidates = _sessions.values
        .where((s) =>
            !s.isGenerating && (_observerCount[s.conversationId] ?? 0) == 0)
        .toList()
      ..sort((a, b) => a.lastActivity.compareTo(b.lastActivity));

    var over = _sessions.length - maxActiveSessions;
    for (final s in candidates) {
      if (over <= 0) break;
      _log.fine('LRU evicting ${s.conversationId} '
          '(idle since ${s.lastActivity.toIso8601String()})');
      _sessions.remove(s.conversationId);
      _observerCount.remove(s.conversationId);
      s.dispose().ignore();
      over--;
    }
  }
}
