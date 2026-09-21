import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/chat_session_state.dart';
import '../../../domain/models/message.dart';
import '../../providers/chat_input_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../widgets/message_bubble.dart';
import 'chat_composer.dart';
import 'chat_empty_states.dart';
import 'chat_header.dart';
import 'message_grouping.dart';

/// Centre panel: header, message list, error banner, composer.
///
/// Owns only the list's presentation state — scroll position and the
/// "stick to bottom" flag. The message being written is [ChatComposer]'s;
/// this widget only wraps the whole panel in a drop zone that feeds it.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key});

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _scrollController = ScrollController();
  final _composerKey = GlobalKey<ChatComposerState>();
  bool _stickToBottom = true;
  bool _scrollPending = false;
  bool _needsInitialScroll = false;
  String? _lastConversationId;
  bool _dragHover = false;

  // Derived per message list; recomputed only when the list identity
  // changes, not on every rebuild.
  List<Message>? _cachedMessages;
  List<List<Message>> _grouped = const [];
  Map<String, int> _cumulativeDurations = const {};

  /// Tolerance (in pixels) for "at the bottom" detection. Kept tiny so
  /// re-attach only fires when the user deliberately scrolls all the way
  /// down, not when they stop a bit above. A few pixels of slack absorb
  /// rounding and the race where maxScrollExtent grows by a streaming
  /// delta between the gesture release and the idle event.
  static const _bottomTolerance = 4.0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // --- Scrolling ---------------------------------------------------------

  bool _isAtBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels <= _bottomTolerance;
  }

  /// [UserScrollNotification] fires only on real user gestures, so the
  /// auto-scroll's own `animateTo` calls don't feed back into this handler.
  bool _onUserScroll(UserScrollNotification n) {
    if (n.direction == ScrollDirection.reverse) {
      // User pulls toward top of history — detach.
      if (_stickToBottom) setState(() => _stickToBottom = false);
    } else if (n.direction == ScrollDirection.idle) {
      // Gesture released — re-attach if user landed at the bottom.
      if (!_stickToBottom && _isAtBottom()) {
        setState(() => _stickToBottom = true);
      }
    }
    return false;
  }

  void _scrollToBottom({bool force = false, bool jump = false}) {
    if (!force && !_stickToBottom) return;
    if (_scrollPending) return;
    // Starting an animation during an active user gesture replaces the
    // drag activity and cancels the user's scroll.
    if (_scrollController.hasClients &&
        _scrollController.position.userScrollDirection !=
            ScrollDirection.idle) {
      return;
    }
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (jump) {
        _scrollController.jumpTo(target);
        // Variable-height items may not be fully laid out yet — re-check
        // after the next frame and correct if needed.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) return;
          final updated = _scrollController.position.maxScrollExtent;
          if (updated > target) _scrollController.jumpTo(updated);
        });
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onSent() {
    setState(() => _stickToBottom = true);
    _scrollToBottom(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final conversationId = ref.watch(conversationControllerProvider);
    if (conversationId != _lastConversationId) {
      _lastConversationId = conversationId;
      _stickToBottom = true;
      _needsInitialScroll = true;
    }
    if (conversationId == null) return const NoConversationSelected();

    final session = ref.watch(chatSessionProvider(conversationId));
    final messagesAsync = ref.watch(
      conversationMessagesProvider(conversationId),
    );
    final totalCount = ref
        .watch(conversationMessageCountProvider(conversationId))
        .whenOrNull(data: (v) => v);
    final windowSize = ref.watch(messageWindowSizeProvider(conversationId));

    return ValueListenableBuilder<ChatSessionState>(
      valueListenable: session.state,
      builder: (context, sessionState, _) {
        final streaming = sessionState is SessionStreaming
            ? sessionState
            : null;
        final column = Column(
          children: [
            ChatHeader(session: session),
            const Divider(height: 1),
            Expanded(
              child: messagesAsync.when(
                data: (messages) => _buildMessageList(
                  messages,
                  conversationId: conversationId,
                  hasMoreAbove: totalCount != null && totalCount > windowSize,
                  atWindowCap: windowSize >= kMaxMessageWindowSize,
                  streamingMessageId: streaming?.streamingMessageId,
                  progress: streaming?.progress,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) =>
                    Center(child: Text('Error loading messages: $e')),
              ),
            ),
            if (sessionState case SessionError(:final message))
              _ErrorBanner(message: message, onDismiss: session.clearError),
            const Divider(height: 1),
            ChatComposer(
              key: _composerKey,
              conversationId: conversationId,
              session: session,
              isGenerating: sessionState.isGenerating,
              onSent: _onSent,
            ),
          ],
        );
        // Whole panel is a drop zone so files can land on the list too.
        return DropTarget(
          enable: !sessionState.isGenerating,
          onDragEntered: (_) => setState(() => _dragHover = true),
          onDragExited: (_) => setState(() => _dragHover = false),
          onDragDone: (details) {
            setState(() => _dragHover = false);
            unawaited(
              _composerKey.currentState?.attachFiles([
                for (final f in details.files)
                  (name: f.name, read: f.readAsBytes),
              ]),
            );
          },
          child: Stack(
            children: [column, if (_dragHover) const _DropOverlay()],
          ),
        );
      },
    );
  }

  Widget _buildMessageList(
    List<Message> messages, {
    required String conversationId,
    required bool hasMoreAbove,
    required bool atWindowCap,
    String? streamingMessageId,
    GenerationProgress? progress,
  }) {
    if (messages.isEmpty) return const WelcomeMessage();

    if (_needsInitialScroll) {
      _needsInitialScroll = false;
      _scrollToBottom(force: true, jump: true);
    } else {
      _scrollToBottom();
    }

    if (!identical(messages, _cachedMessages)) {
      _cachedMessages = messages;
      _grouped = groupMessages(messages);
      _cumulativeDurations = cumulativeDurations(messages);
    }
    final headerCount = hasMoreAbove ? 1 : 0;

    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: _onUserScroll,
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 16),
            itemCount: _grouped.length + headerCount,
            itemBuilder: (context, index) {
              if (hasMoreAbove && index == 0) {
                return LoadMoreHeader(
                  atCap: atWindowCap,
                  onLoadMore: () => ref
                      .read(messageWindowSizeProvider(conversationId).notifier)
                      .expand(),
                );
              }
              final group = _grouped[index - headerCount];
              final head = group.first;
              // Isolate each bubble from paint invalidation so a streaming
              // bubble at the tail doesn't repaint the whole scrollback.
              return RepaintBoundary(
                child: MessageBubble(
                  key: ValueKey(head.id),
                  message: head,
                  toolResults: group.sublist(1),
                  cumulativeDurationMs: _cumulativeDurations[head.id],
                  progress: head.id == streamingMessageId ? progress : null,
                  onTellMore: (selection) => ref
                      .read(chatInputInjectionProvider.notifier)
                      .inject('Tell me more about: "$selection"'),
                  onFork: (text) => ref
                      .read(conversationControllerProvider.notifier)
                      .fork(conversationId, draft: text)
                      .ignore(),
                ),
              );
            },
          ),
        ),
        if (!_stickToBottom)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: _ScrollToBottomButton(
                onTap: () {
                  setState(() => _stickToBottom = true);
                  _scrollToBottom(force: true);
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// Translucent veil with a hint while a file is dragged over the panel.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.08),
            border: Border.all(color: cs.primary, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_photo_alternate_outlined, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                'Drop images to attach',
                style: TextStyle(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScrollToBottomButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ScrollToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      shape: const CircleBorder(),
      color: cs.primaryContainer,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            Icons.keyboard_arrow_down,
            size: 22,
            color: cs.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: cs.errorContainer,
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: cs.onErrorContainer),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: cs.onErrorContainer),
            onPressed: onDismiss,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
          ),
        ],
      ),
    );
  }
}
