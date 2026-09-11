import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// Shown when no conversation is selected.
class NoConversationSelected extends StatelessWidget {
  const NoConversationSelected({super.key});

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: styles.textFaint.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'Select or create a conversation',
            style: TextStyle(fontSize: 16, color: styles.textFaint),
          ),
        ],
      ),
    );
  }
}

/// Shown inside an empty conversation.
class WelcomeMessage extends StatelessWidget {
  const WelcomeMessage({super.key});

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Start a conversation',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: styles.textSubtle,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Type a message below to begin',
            style: TextStyle(
              fontSize: 14,
              color: styles.textFaint.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Load older messages" header at the top of a windowed list.
class LoadMoreHeader extends StatelessWidget {
  final bool atCap;
  final VoidCallback onLoadMore;

  const LoadMoreHeader({
    super.key,
    required this.atCap,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: atCap
            ? Text(
                'Older messages archived',
                style: styles.small.copyWith(color: styles.textFaint),
              )
            : TextButton.icon(
                onPressed: onLoadMore,
                icon: const Icon(Icons.history, size: 16),
                label: const Text('Load older messages'),
                style: TextButton.styleFrom(foregroundColor: styles.textMuted),
              ),
      ),
    );
  }
}
