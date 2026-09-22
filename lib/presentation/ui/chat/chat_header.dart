import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/chat/chat_session.dart';
import '../../../core/theme.dart';
import '../../../domain/chat_session_state.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/effective_settings_provider.dart';
import '../widgets/token_text.dart';

/// Conversation title and context-usage gauge.
class ChatHeader extends ConsumerWidget {
  final ChatSession session;

  const ChatHeader({super.key, required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(
      selectedConversationProvider.select((c) => c?.title),
    );
    final contextLength = ref.watch(
      effectiveSettingsProvider.select((s) => s.contextLength),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.chat, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title ?? 'Chat',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // The session's state notifier is the source of truth for token
          // counts. Rebuild the gauge alone when it changes.
          ValueListenableBuilder<ChatSessionState>(
            valueListenable: session.state,
            builder: (context, s, _) {
              final tokens = s.promptTokens;
              if (tokens <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(left: 12),
                child: ContextGauge(used: tokens, total: contextLength),
              );
            },
          ),
        ],
      ),
    );
  }
}

class ContextGauge extends StatelessWidget {
  final int used;
  final int total;

  const ContextGauge({super.key, required this.used, required this.total});

  @override
  Widget build(BuildContext context) {
    final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final cs = Theme.of(context).colorScheme;
    final color = ratio < 0.7
        ? cs.primary
        : ratio < 0.9
        ? Colors.orange
        : cs.error;

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
                backgroundColor: cs.surfaceContainerHighest,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${formatTokens(used)} / ${formatTokens(total)}',
            style: context.specterStyles.caption,
          ),
        ],
      ),
    );
  }
}
