import 'package:flutter/material.dart';
// ignore: unnecessary_import — needed for ScrollDirection at runtime.
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/chat_session.dart';
import '../../domain/chat_session_state.dart';
import '../../models/message.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/effective_settings_provider.dart';
import '../../providers/mcp_provider.dart';
import '../widgets/message_bubble.dart';

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
  String? _lastConversationId;
  List<Message>? _cachedMessages;
  List<List<Message>>? _cachedGrouped;
  Map<String, int>? _cachedCumulativeDurations;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  /// Tolerance (in pixels) for "at the bottom" detection. Kept tiny so
  /// re-attach only fires when the user deliberately scrolls all the way
  /// down, not when they stop a bit above. A few pixels of slack absorb
  /// rounding and the race where maxScrollExtent grows by a streaming
  /// delta between the gesture release and the idle event.
  static const _bottomTolerance = 4.0;

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
      if (_stickToBottom) {
        setState(() => _stickToBottom = false);
      }
    } else if (n.direction == ScrollDirection.idle) {
      // Gesture released — re-attach if user landed at the bottom.
      if (!_stickToBottom && _isAtBottom()) {
        setState(() => _stickToBottom = true);
      }
    }
    return false;
  }

  bool _scrollPending = false;
  bool _needsInitialScroll = false;

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
        // Variable-height items may not be fully laid out yet.
        // Re-check after the next frame and correct if needed.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) return;
          final updated = _scrollController.position.maxScrollExtent;
          if (updated > target) {
            _scrollController.jumpTo(updated);
          }
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

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(chatInputInjectionProvider, (prev, next) {
      if (next == null || next.isEmpty) return;
      final current = _inputController.text;
      final separator = current.isEmpty || current.endsWith('\n') ? '' : '\n';
      _inputController.text = '$current$separator$next';
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
      _inputFocusNode.requestFocus();
      // One-shot: reset so back-to-back identical injections re-trigger.
      ref.read(chatInputInjectionProvider.notifier).state = null;
    });

    final conversationId = ref.watch(selectedConversationIdProvider);
    if (conversationId != _lastConversationId) {
      _lastConversationId = conversationId;
      _stickToBottom = true;
      _needsInitialScroll = true;
    }

    if (conversationId == null) {
      return _EmptyState();
    }

    final session = ref.watch(chatSessionProvider(conversationId));
    final messagesAsync =
        ref.watch(conversationMessagesProvider(conversationId));
    final totalCount = ref
        .watch(conversationMessageCountProvider(conversationId))
        .whenOrNull(data: (v) => v);
    final windowSize =
        ref.watch(messageWindowSizeProvider(conversationId));
    final atWindowCap = windowSize >= kMaxMessageWindowSize;
    final hasMoreAbove =
        totalCount != null && totalCount > windowSize;

    return ValueListenableBuilder<ChatSessionState>(
      valueListenable: session.state,
      builder: (context, sessionState, _) {
        final isGenerating = sessionState.isGenerating;
        final error =
            sessionState is SessionError ? sessionState.message : null;

        return Column(
          children: [
            _ChatHeader(session: session),
            const Divider(height: 1),
            Expanded(
              child: messagesAsync.when(
                data: (messages) => _buildMessageList(
                  messages,
                  conversationId: conversationId,
                  hasMoreAbove: hasMoreAbove,
                  atWindowCap: atWindowCap,
                ),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) =>
                    Center(child: Text('Error loading messages: $e')),
              ),
            ),
            if (error != null) _buildErrorBanner(context, session, error),
            const Divider(height: 1),
            _InputArea(
              controller: _inputController,
              focusNode: _inputFocusNode,
              isGenerating: isGenerating,
              onSend: () => _sendMessage(session),
              onStop: session.stop,
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
    if (messages.isEmpty) {
      return _WelcomeMessage();
    }

    if (_needsInitialScroll) {
      _needsInitialScroll = false;
      _scrollToBottom(force: true, jump: true);
    } else {
      _scrollToBottom();
    }

    if (!identical(messages, _cachedMessages)) {
      _cachedMessages = messages;
      _cachedGrouped = _groupMessages(messages);
      _cachedCumulativeDurations = _computeCumulativeDurations(messages);
    }
    final grouped = _cachedGrouped!;
    final cumulativeDurations = _cachedCumulativeDurations!;
    final int headerCount = hasMoreAbove ? 1 : 0;

    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: _onUserScroll,
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 16),
            itemCount: grouped.length + headerCount,
            itemBuilder: (context, index) {
              if (hasMoreAbove && index == 0) {
                return _LoadMoreHeader(
                  atCap: atWindowCap,
                  onLoadMore: () => _loadMore(conversationId),
                );
              }
              final group = grouped[index - headerCount];
              final cumulativeMs = cumulativeDurations[group.first.id];
              final bubble = group.length == 1
                  ? MessageBubble(
                      key: ValueKey(group.first.id),
                      message: group.first,
                      cumulativeDurationMs: cumulativeMs,
                    )
                  : MessageBubble(
                      key: ValueKey(group.first.id),
                      message: group.first,
                      toolResults: group.sublist(1),
                      cumulativeDurationMs: cumulativeMs,
                    );
              // Isolate each bubble from paint invalidation so a streaming
              // bubble at the tail doesn't repaint the whole scrollback.
              return RepaintBoundary(child: bubble);
            },
          ),
        ),
        if (!_stickToBottom)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                elevation: 4,
                shape: const CircleBorder(),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    setState(() => _stickToBottom = true);
                    _scrollToBottom(force: true);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 22,
                      color: Theme.of(context)
                          .colorScheme
                          .onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildErrorBanner(
      BuildContext context, ChatSession session, String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.error_outline,
              size: 16,
              color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close,
                size: 16,
                color: Theme.of(context).colorScheme.onErrorContainer),
            onPressed: session.clearError,
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(maxWidth: 24, maxHeight: 24),
          ),
        ],
      ),
    );
  }

  /// Cumulative assistant duration (ms) since the last user message,
  /// inclusive of each message's own duration.
  static Map<String, int> _computeCumulativeDurations(List<Message> messages) {
    final result = <String, int>{};
    int running = 0;
    for (final msg in messages) {
      if (msg.role == MessageRole.user) {
        running = 0;
      } else if (msg.role == MessageRole.assistant) {
        running += msg.durationMs;
        result[msg.id] = running;
      }
    }
    return result;
  }

  /// Group each tool-result message with the assistant that called it.
  /// UUIDv7 ids guarantee `ORDER BY id` is insertion order, so tool
  /// messages always follow their owning assistant — simple adjacency
  /// suffices.
  static List<List<Message>> _groupMessages(List<Message> messages) {
    final groups = <List<Message>>[];
    for (final msg in messages) {
      if (msg.role == MessageRole.tool && groups.isNotEmpty) {
        groups.last.add(msg);
      } else {
        groups.add([msg]);
      }
    }
    return groups;
  }

  void _sendMessage(ChatSession session) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _inputController.clear();
    setState(() => _stickToBottom = true);
    _scrollToBottom(force: true);
    session.sendMessage(text);
  }

  void _loadMore(String conversationId) {
    ref.read(messageWindowSizeProvider(conversationId).notifier).expand();
  }
}

class _LoadMoreHeader extends StatelessWidget {
  final bool atCap;
  final VoidCallback onLoadMore;

  const _LoadMoreHeader({
    required this.atCap,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: atCap
            ? Text(
                'Older messages archived',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.4),
                ),
              )
            : TextButton.icon(
                onPressed: onLoadMore,
                icon: const Icon(Icons.history, size: 16),
                label: const Text('Load older messages'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
      ),
    );
  }
}

class _ChatHeader extends ConsumerWidget {
  final ChatSession session;

  const _ChatHeader({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversation = ref.watch(selectedConversationProvider);
    final contextLength = ref.watch(
        effectiveSettingsProvider.select((s) => s.contextLength));
    // The session's [state] ValueNotifier is the source of truth for
    // token counts. Rebuild the gauge alone when it changes, leaving
    // the rest of the header cached.
    final used = ValueListenableBuilder<ChatSessionState>(
      valueListenable: session.state,
      builder: (context, s, _) {
        final tokens = s.promptTokens;
        if (tokens <= 0) return const SizedBox.shrink();
        final ratio = contextLength > 0
            ? (tokens / contextLength).clamp(0.0, 1.0)
            : 0.0;
        return Padding(
          padding: const EdgeInsets.only(left: 12),
          child: _ContextGauge(
            ratio: ratio,
            used: tokens,
            total: contextLength,
          ),
        );
      },
    );

    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.chat, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              conversation?.title ?? 'Chat',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          used,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'Select or create a conversation',
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomeMessage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: 48,
            color: Theme.of(context)
                .colorScheme
                .primary
                .withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Start a conversation',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Type a message below to begin',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _InputArea extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isGenerating;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _InputArea({
    required this.controller,
    required this.focusNode,
    required this.isGenerating,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed &&
                    !isGenerating) {
                  onSend();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                maxLines: 6,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  filled: true,
                  fillColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                ),
                enabled: !isGenerating,
              ),
            ),
          ),
          const SizedBox(width: 8),
          isGenerating
              ? IconButton.filled(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop),
                  tooltip: 'Stop generation',
                  style: IconButton.styleFrom(
                    backgroundColor:
                        Theme.of(context).colorScheme.error,
                    foregroundColor:
                        Theme.of(context).colorScheme.onError,
                  ),
                )
              : IconButton.filled(
                  onPressed: onSend,
                  icon: const Icon(Icons.send),
                  tooltip: 'Send (Enter)',
                ),
        ],
      ),
    );
  }
}

class _ContextGauge extends StatelessWidget {
  final double ratio;
  final int used;
  final int total;

  const _ContextGauge({
    required this.ratio,
    required this.used,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final color = ratio < 0.7
        ? Theme.of(context).colorScheme.primary
        : ratio < 0.9
            ? Colors.orange
            : Theme.of(context).colorScheme.error;

    final label = '${_formatTokens(used)} / ${_formatTokens(total)}';

    return Tooltip(
      message: '$used / $total tokens (${(ratio * 100).round()}%)',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 60,
            height: 6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTokens(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}K';
    }
    return tokens.toString();
  }
}
