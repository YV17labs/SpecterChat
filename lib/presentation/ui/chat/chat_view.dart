import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/chat/chat_session.dart';
import '../../../domain/chat_session_state.dart';
import '../../../domain/models/message.dart';
import '../../providers/chat_input_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../widgets/message_bubble.dart';
import 'chat_empty_states.dart';
import 'chat_header.dart';
import 'chat_input_area.dart';
import 'message_grouping.dart';

/// Centre panel: header, message list, error banner, composer.
///
/// Owns only presentation state — the text controller, scroll position
/// and the "stick to bottom" flag. Everything else is read from providers
/// and acted on through the session handle or a controller.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key});

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  bool _stickToBottom = true;
  bool _scrollPending = false;
  bool _needsInitialScroll = false;
  String? _lastConversationId;

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
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

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

  void _appendToInput(String text) {
    final current = _inputController.text;
    final separator = current.isEmpty || current.endsWith('\n') ? '' : '\n';
    _inputController.text = '$current$separator$text';
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
    _inputFocusNode.requestFocus();
  }

  void _sendMessage(ChatSession session) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() => _stickToBottom = true);
    _scrollToBottom(force: true);
    session.sendMessage(text).ignore();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(chatInputInjectionProvider, (_, next) {
      if (next == null || next.isEmpty) return;
      _appendToInput(next);
      ref.read(chatInputInjectionProvider.notifier).consume();
    });

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
        return Column(
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
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) =>
                    Center(child: Text('Error loading messages: $e')),
              ),
            ),
            if (sessionState case SessionError(:final message))
              _ErrorBanner(message: message, onDismiss: session.clearError),
            const Divider(height: 1),
            ChatInputArea(
              controller: _inputController,
              focusNode: _inputFocusNode,
              isGenerating: sessionState.isGenerating,
              onSend: () => _sendMessage(session),
              onStop: () => session.stop().ignore(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMessageList(
    List<Message> messages, {
    required String conversationId,
    required bool hasMoreAbove,
    required bool atWindowCap,
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
