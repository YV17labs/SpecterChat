import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/message.dart';
import '../../services/llm_hooks/llm_hooks.dart' as llm_hooks;
import '../../utils/theme.dart';
import 'content_blocks.dart';

// Auto-correction bubble colors.
const _correctionBg = Color(0x26FFC107); // amber @ 0.15
const _correctionBorder = Color(0x66FFC107); // amber @ 0.4
const _correctionAvatarBg = Color(0x33FFC107); // amber @ 0.2
const _correctionAccent = Color(0xFFFFCA28); // amber.shade300

class MessageBubble extends StatelessWidget {
  final Message message;
  final List<Message> toolResults;

  const MessageBubble({
    super.key,
    required this.message,
    this.toolResults = const [],
  });

  /// Whether this message is an auto-injected hallucination correction.
  bool get _isAutoCorrection {
    if (message.role != MessageRole.user) return false;
    final text = message.content
        .whereType<TextContentBlock>()
        .map((b) => b.text)
        .join();
    return text.startsWith(llm_hooks.correctionPrefix);
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final isAutoCorrection = _isAutoCorrection;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser && !isAutoCorrection
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            const _Avatar(kind: _AvatarKind.assistant),
            const SizedBox(width: 8),
          ],
          if (isAutoCorrection) ...[
            const _Avatar(kind: _AvatarKind.autoCorrection),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _maybeCopyWrapper(
                  context,
                  message,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth:
                          MediaQuery.of(context).size.width * 0.65,
                    ),
                    decoration: BoxDecoration(
                      color: isAutoCorrection
                          ? _correctionBg
                          : isUser
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHigh,
                      border: isAutoCorrection
                          ? Border.all(
                              color: _correctionBorder,
                              width: 1,
                            )
                          : null,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft:
                            isUser && !isAutoCorrection
                                ? const Radius.circular(16)
                                : Radius.zero,
                        bottomRight:
                            isUser && !isAutoCorrection
                                ? Radius.zero
                                : const Radius.circular(16),
                      ),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isAutoCorrection)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 4),
                            child: Text(
                              'Auto-correction',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _correctionAccent,
                              ),
                            ),
                          ),
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
                      decoration: Theme.of(context)
                          .extension<SpecterStyles>()!
                          .toolResultGroupDecoration,
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
            const _Avatar(kind: _AvatarKind.user),
          ],
        ],
      ),
    );
  }
}

/// Extracts text content from a message for clipboard copy.
String _extractCopyText(Message message) {
  final parts = <String>[];
  for (final block in message.content) {
    if (block is TextContentBlock && block.text.trim().isNotEmpty) {
      parts.add(block.text.trim());
    }
  }
  return parts.join('\n');
}

/// Wraps the child with a copy button only for user messages
/// and assistant messages that have a real text response
/// (not just thinking + tool calls).
Widget _maybeCopyWrapper(
    BuildContext context, Message message, {required Widget child}) {
  if (message.role == MessageRole.user) {
    final copyText = _extractCopyText(message);
    if (copyText.isNotEmpty) {
      return _HoverCopyWrapper(copyText: copyText, child: child);
    }
  }
  if (message.role == MessageRole.assistant && !message.isStreaming) {
    final copyText = _extractCopyText(message);
    if (copyText.isNotEmpty) {
      return _HoverCopyWrapper(copyText: copyText, child: child);
    }
  }
  return child;
}

/// Shows a copy button on hover, positioned at the top-right of the child.
class _HoverCopyWrapper extends StatefulWidget {
  final String copyText;
  final Widget child;

  const _HoverCopyWrapper({required this.copyText, required this.child});

  @override
  State<_HoverCopyWrapper> createState() => _HoverCopyWrapperState();
}

class _HoverCopyWrapperState extends State<_HoverCopyWrapper> {
  bool _hovering = false;
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.copyText));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          widget.child,
          if (_hovering)
            Positioned(
              bottom: 8,
              right: 8,
              child: IconButton(
                icon: Icon(
                  _copied ? Icons.check : Icons.copy,
                  size: 14,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5),
                ),
                onPressed: _copy,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(maxWidth: 24, maxHeight: 24),
                tooltip: _copied ? 'Copied!' : 'Copy',
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.8),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _AvatarKind { user, assistant, autoCorrection }

class _Avatar extends StatelessWidget {
  final _AvatarKind kind;

  const _Avatar({required this.kind});

  @override
  Widget build(BuildContext context) {
    if (kind == _AvatarKind.autoCorrection) {
      return const CircleAvatar(
        radius: 16,
        backgroundColor: _correctionAvatarBg,
        child: Icon(
          Icons.auto_fix_high,
          size: 18,
          color: _correctionAccent,
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;
    final isAssistant = kind == _AvatarKind.assistant;
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
              .withValues(alpha: 0.35),
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
        :final resultContent,
        :final rawResponse
      ) =>
        ToolResultBlock(
          toolName: toolName,
          resultContent: resultContent,
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
                .withValues(alpha: 0.3 + _controller.value * 0.4),
          ),
        );
      },
    );
  }
}
