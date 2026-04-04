import 'package:flutter/material.dart';

import '../../models/message.dart';
import 'content_blocks.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final List<Message> toolResults;

  const MessageBubble({
    super.key,
    required this.message,
    this.toolResults = const [],
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            const _Avatar(isAssistant: true),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: BoxConstraints(
                    maxWidth:
                        MediaQuery.of(context).size.width * 0.65,
                  ),
                  decoration: BoxDecoration(
                    color: isUser
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context)
                            .colorScheme
                            .surfaceContainerHigh,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft:
                          isUser ? const Radius.circular(16) : Radius.zero,
                      bottomRight:
                          isUser ? Radius.zero : const Radius.circular(16),
                    ),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final block in message.content)
                        _ContentBlockWidget(block: block),
                      if (message.isStreaming) const _StreamingIndicator(),
                      if (!message.isStreaming &&
                          message.role == MessageRole.assistant &&
                          message.completionTokens > 0)
                        _MessageStats(
                          tokens: message.completionTokens,
                          durationMs: message.durationMs,
                        ),
                    ],
                  ),
                ),
                // Tool results rendered inside the same bubble group.
                for (final toolMsg in toolResults)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth:
                            MediaQuery.of(context).size.width * 0.65,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .tertiaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final block in toolMsg.content)
                            _ContentBlockWidget(block: block),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            const _Avatar(isAssistant: false),
          ],
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final bool isAssistant;

  const _Avatar({required this.isAssistant});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 16,
      backgroundColor: isAssistant ? cs.secondary : cs.primary,
      child: Icon(
        isAssistant ? Icons.smart_toy : Icons.person,
        size: 18,
        color: isAssistant ? cs.onSecondary : cs.onPrimary,
      ),
    );
  }
}

class _MessageStats extends StatelessWidget {
  final int tokens;
  final int durationMs;

  const _MessageStats({required this.tokens, required this.durationMs});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    parts.add('$tokens tokens');
    if (durationMs > 0) {
      final seconds = durationMs / 1000;
      final tokPerSec =
          seconds > 0 ? (tokens / seconds).toStringAsFixed(1) : '—';
      parts.add('${seconds.toStringAsFixed(1)}s');
      parts.add('$tokPerSec tok/s');
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        parts.join('  ·  '),
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context)
              .colorScheme
              .onSurface
              .withOpacity(0.35),
        ),
      ),
    );
  }
}

class _ContentBlockWidget extends StatelessWidget {
  final ContentBlock block;

  const _ContentBlockWidget({required this.block});

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      TextContentBlock(:final text) => TextBlock(text: text),
      ImageContentBlock(:final base64Data, :final mimeType) =>
        ImageBlock(base64Data: base64Data, mimeType: mimeType),
      ToolCallContentBlock(:final name, :final arguments) =>
        ToolCallBlock(name: name, arguments: arguments),
      ToolResultContentBlock(
        :final toolName,
        :final content,
        :final imageBase64,
        :final imageMimeType,
        :final rawResponse
      ) =>
        ToolResultBlock(
          toolName: toolName,
          content: content,
          imageBase64: imageBase64,
          imageMimeType: imageMimeType,
          rawResponse: rawResponse,
        ),
      ThinkingContentBlock(:final text) => ThinkingBlock(text: text),
    };
  }
}

class _StreamingIndicator extends StatelessWidget {
  const _StreamingIndicator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        width: 24,
        height: 8,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: _DotAnimation(delay: i * 200),
            );
          }),
        ),
      ),
    );
  }
}

class _DotAnimation extends StatefulWidget {
  final int delay;
  const _DotAnimation({required this.delay});

  @override
  State<_DotAnimation> createState() => _DotAnimationState();
}

class _DotAnimationState extends State<_DotAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withOpacity(0.3 + _controller.value * 0.4),
          ),
        );
      },
    );
  }
}
