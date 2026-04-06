import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/effective_settings_provider.dart';
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
  bool _userHasScrolledUp = false;
  String? _lastConversationId;
  List<Message>? _cachedMessages;
  List<List<Message>>? _cachedGrouped;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  /// Distance from the bottom within which we auto-follow new content.
  static const _autoFollowThreshold = 150.0;

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final nearBottom =
        pos.maxScrollExtent - pos.pixels <= _autoFollowThreshold;
    if (nearBottom != !_userHasScrolledUp) {
      setState(() => _userHasScrolledUp = !nearBottom);
    }
  }

  bool _scrollPending = false;
  bool _needsInitialScroll = false;

  void _scrollToBottom({bool force = false, bool jump = false}) {
    if (!force && _userHasScrolledUp) return;
    if (_scrollPending) return;
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
    final conversationId =
        ref.watch(selectedConversationIdProvider);
    if (conversationId != _lastConversationId) {
      _lastConversationId = conversationId;
      _userHasScrolledUp = false;
      _needsInitialScroll = true;
    }
    final streamingMessages = ref.watch(
        chatProvider.select((s) => s.streamingMessages));
    final isGenerating = ref.watch(
        chatProvider.select((s) => s.isGenerating));
    final error = ref.watch(
        chatProvider.select((s) => s.error));

    if (conversationId == null) {
      return _EmptyState();
    }

    final messagesAsync =
        ref.watch(conversationMessagesProvider(conversationId));

    return Column(
      children: [
        _ChatHeader(conversationId: conversationId),

        const Divider(height: 1),

        Expanded(
          child: messagesAsync.when(
            data: (messages) {
              if (messages.isEmpty && streamingMessages.isEmpty) {
                return _WelcomeMessage();
              }

              if (_needsInitialScroll) {
                _needsInitialScroll = false;
                _scrollToBottom(force: true, jump: true);
              } else {
                _scrollToBottom();
              }

              // Memoize grouping of persisted messages — only
              // recompute when the DB list identity changes.
              if (!identical(messages, _cachedMessages)) {
                _cachedMessages = messages;
                _cachedGrouped = _groupMessages(messages);
              }
              // Append streaming messages without re-grouping everything.
              final grouped = [
                ..._cachedGrouped!,
                if (streamingMessages.isNotEmpty)
                  streamingMessages,
              ];

              return Stack(
                children: [
                  ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    itemCount: grouped.length,
                    itemBuilder: (context, index) {
                      final group = grouped[index];
                      if (group.length == 1) {
                        return MessageBubble(
                          key: ValueKey(group.first.id),
                          message: group.first,
                        );
                      }
                      // Assistant + tool results merged.
                      return MessageBubble(
                        key: ValueKey(group.first.id),
                        message: group.first,
                        toolResults: group.sublist(1),
                      );
                    },
                  ),
                  if (_userHasScrolledUp)
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Material(
                          elevation: 4,
                          shape: const CircleBorder(),
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _scrollToBottom(force: true),
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
            },
            loading: () => const Center(
                child: CircularProgressIndicator()),
            error: (e, _) =>
                Center(child: Text('Error loading messages: $e')),
          ),
        ),

        // Error display
        if (error != null)
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Row(
              children: [
                Icon(Icons.error_outline,
                    size: 16,
                    color:
                        Theme.of(context).colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context)
                          .colorScheme
                          .onErrorContainer,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 16,
                      color: Theme.of(context)
                          .colorScheme
                          .onErrorContainer),
                  onPressed: () => ref.read(chatProvider.notifier)
                      .clearError(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      maxWidth: 24, maxHeight: 24),
                ),
              ],
            ),
          ),

        const Divider(height: 1),

        // Input area
        _InputArea(
          controller: _inputController,
          focusNode: _inputFocusNode,
          isGenerating: isGenerating,
          onSend: () => _sendMessage(conversationId),
          onStop: () =>
              ref.read(chatProvider.notifier).stopGeneration(),
        ),
      ],
    );
  }

  /// Group tool-result messages with their preceding assistant message.
  static List<List<Message>> _groupMessages(List<Message> messages) {
    final groups = <List<Message>>[];
    for (final msg in messages) {
      if (msg.role == MessageRole.tool && groups.isNotEmpty) {
        // Attach to the last group (should be an assistant).
        groups.last.add(msg);
      } else {
        groups.add([msg]);
      }
    }
    return groups;
  }

  void _sendMessage(String conversationId) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _inputController.clear();
    setState(() => _userHasScrolledUp = false);
    _scrollToBottom(force: true);
    ref
        .read(chatProvider.notifier)
        .sendMessage(conversationId, text);
  }
}

class _ChatHeader extends ConsumerWidget {
  final String conversationId;

  const _ChatHeader({required this.conversationId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversation = ref.watch(selectedConversationProvider);
    final used = ref.watch(
        chatProvider.select((s) => s.promptTokens));
    final contextLength = ref.watch(
        effectiveSettingsProvider.select((s) => s.contextLength));
    final ratio = contextLength > 0
        ? (used / contextLength).clamp(0.0, 1.0)
        : 0.0;

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
          if (used > 0) ...[
            const SizedBox(width: 12),
            _ContextGauge(ratio: ratio, used: used, total: contextLength),
          ],
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
                .withOpacity(0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'Select or create a conversation',
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withOpacity(0.4),
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
                .withOpacity(0.5),
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
                  .withOpacity(0.5),
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
                  .withOpacity(0.3),
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
                          .withOpacity(0.3),
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
                  .withOpacity(0.5),
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
