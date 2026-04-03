import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/message.dart';

class MessageBubble extends StatelessWidget {
  final Message message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final isTool = message.role == MessageRole.tool;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            _Avatar(isUser: false, isTool: isTool),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth:
                    MediaQuery.of(context).size.width * 0.65,
              ),
              decoration: BoxDecoration(
                color: isUser
                    ? Theme.of(context).colorScheme.primaryContainer
                    : isTool
                        ? Theme.of(context)
                            .colorScheme
                            .tertiaryContainer
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
                  if (message.isStreaming) _StreamingIndicator(),
                ],
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            _Avatar(isUser: true, isTool: false),
          ],
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final bool isUser;
  final bool isTool;

  const _Avatar({required this.isUser, required this.isTool});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 16,
      backgroundColor: isUser
          ? Theme.of(context).colorScheme.primary
          : isTool
              ? Theme.of(context).colorScheme.tertiary
              : Theme.of(context).colorScheme.secondary,
      child: Icon(
        isUser
            ? Icons.person
            : isTool
                ? Icons.build
                : Icons.smart_toy,
        size: 18,
        color: isUser
            ? Theme.of(context).colorScheme.onPrimary
            : isTool
                ? Theme.of(context).colorScheme.onTertiary
                : Theme.of(context).colorScheme.onSecondary,
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
      TextContentBlock(:final text) => _TextBlock(text: text),
      ImageContentBlock(:final base64Data, :final mimeType) =>
        _ImageBlock(base64Data: base64Data, mimeType: mimeType),
      ToolCallContentBlock(
        :final name,
        :final arguments,
        :final id
      ) =>
        _ToolCallBlock(name: name, arguments: arguments, id: id),
      ToolResultContentBlock(
        :final toolName,
        :final content,
        :final imageBase64,
        :final imageMimeType
      ) =>
        _ToolResultBlock(
          toolName: toolName,
          content: content,
          imageBase64: imageBase64,
          imageMimeType: imageMimeType,
        ),
      ThinkingContentBlock(:final text) =>
        _ThinkingBlock(text: text),
    };
  }
}

class _TextBlock extends StatelessWidget {
  final String text;

  const _TextBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();

    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: Theme.of(context).textTheme.bodyMedium,
        code: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
        codeblockDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        codeblockPadding: const EdgeInsets.all(12),
      ),
    );
  }
}

class _ImageBlock extends StatefulWidget {
  final String base64Data;
  final String mimeType;

  const _ImageBlock(
      {required this.base64Data, required this.mimeType});

  @override
  State<_ImageBlock> createState() => _ImageBlockState();
}

class _ImageBlockState extends State<_ImageBlock> {
  late final Uint8List? _decodedBytes;

  @override
  void initState() {
    super.initState();
    try {
      _decodedBytes = base64Decode(widget.base64Data);
    } catch (_) {
      _decodedBytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_decodedBytes == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('Invalid image data'),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          _decodedBytes,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('Failed to decode image'),
          ),
        ),
      ),
    );
  }
}

/// Reusable expandable container for tool calls, results, and thinking blocks.
class _ExpandableBlock extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final TextStyle? titleStyle;
  final bool initiallyExpanded;
  final Widget child;
  final EdgeInsetsGeometry margin;
  final BoxDecoration? decoration;

  const _ExpandableBlock({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.titleStyle,
    this.initiallyExpanded = false,
    required this.child,
    this.margin = const EdgeInsets.symmetric(vertical: 4),
    this.decoration,
  });

  @override
  State<_ExpandableBlock> createState() => _ExpandableBlockState();
}

class _ExpandableBlockState extends State<_ExpandableBlock> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final decoration = widget.decoration ??
        BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                Theme.of(context).colorScheme.outline.withOpacity(0.3),
          ),
        );

    return Container(
      margin: widget.margin,
      decoration: decoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(widget.icon, size: 14, color: widget.iconColor),
                  const SizedBox(width: 8),
                  Text(
                    widget.title,
                    style: widget.titleStyle ??
                        TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: widget.iconColor,
                        ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) widget.child,
        ],
      ),
    );
  }
}

class _ToolCallBlock extends StatefulWidget {
  final String name;
  final String arguments;
  final String id;

  const _ToolCallBlock({
    required this.name,
    required this.arguments,
    required this.id,
  });

  @override
  State<_ToolCallBlock> createState() => _ToolCallBlockState();
}

class _ToolCallBlockState extends State<_ToolCallBlock> {
  late final String _formattedArgs;

  @override
  void initState() {
    super.initState();
    try {
      final parsed = jsonDecode(widget.arguments);
      const encoder = JsonEncoder.withIndent('  ');
      _formattedArgs = encoder.convert(parsed);
    } catch (_) {
      _formattedArgs = widget.arguments;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ExpandableBlock(
      icon: Icons.build,
      iconColor: Theme.of(context).colorScheme.tertiary,
      title: 'Tool: ${widget.name}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SelectableText(
          _formattedArgs,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withOpacity(0.8),
          ),
        ),
      ),
    );
  }
}

class _ToolResultBlock extends StatelessWidget {
  final String toolName;
  final String content;
  final String? imageBase64;
  final String? imageMimeType;

  const _ToolResultBlock({
    required this.toolName,
    required this.content,
    this.imageBase64,
    this.imageMimeType,
  });

  @override
  Widget build(BuildContext context) {
    return _ExpandableBlock(
      icon: Icons.check_circle_outline,
      iconColor: Theme.of(context).colorScheme.primary,
      title: 'Result: $toolName',
      initiallyExpanded: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SelectableText(
                content,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.8),
                ),
              ),
            ),
          if (imageBase64 != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _ImageBlock(
                base64Data: imageBase64!,
                mimeType: imageMimeType ?? 'image/png',
              ),
            ),
        ],
      ),
    );
  }
}

class _ThinkingBlock extends StatelessWidget {
  final String text;

  const _ThinkingBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    final mutedColor =
        Theme.of(context).colorScheme.onSurface.withOpacity(0.5);

    return _ExpandableBlock(
      icon: Icons.psychology,
      iconColor: mutedColor,
      title: 'Thinking...',
      titleStyle: TextStyle(
        fontSize: 13,
        fontStyle: FontStyle.italic,
        color: mutedColor,
      ),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SelectableText(
          text,
          style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withOpacity(0.6),
          ),
        ),
      ),
    );
  }
}

class _StreamingIndicator extends StatelessWidget {
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
