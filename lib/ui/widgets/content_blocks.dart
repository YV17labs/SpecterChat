import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:logging/logging.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../models/message.dart';
import 'expandable_block.dart';

final _log = Logger('ContentBlocks');

/// Try to pretty-print [text] as JSON. Returns formatted JSON or null.
String? _tryFormatJson(String text) {
  try {
    final parsed = jsonDecode(text);
    return const JsonEncoder.withIndent('  ').convert(parsed);
  } catch (_) {
    return null;
  }
}

/// Common monospace text style for JSON display.
TextStyle _monospaceStyle(BuildContext context) => TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: Theme.of(context)
          .colorScheme
          .onSurface
          .withValues(alpha: 0.8),
    );

/// Renders markdown text content.
class TextBlock extends StatelessWidget {
  final String text;

  const TextBlock({super.key, required this.text});

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

/// Renders a base64-encoded image.
class ImageBlock extends StatefulWidget {
  final String base64Data;
  final String mimeType;

  const ImageBlock(
      {super.key, required this.base64Data, required this.mimeType});

  @override
  State<ImageBlock> createState() => _ImageBlockState();
}

class _ImageBlockState extends State<ImageBlock> {
  Uint8List? _decodedBytes;
  double? _aspectRatio;
  bool _hovering = false;
  bool _justCopied = false;
  Timer? _copiedResetTimer;

  Future<void> _copyToClipboard() async {
    if (_decodedBytes == null) return;
    try {
      await Pasteboard.writeImage(_decodedBytes);
      if (!mounted) return;
      setState(() => _justCopied = true);
      _copiedResetTimer?.cancel();
      _copiedResetTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _justCopied = false);
      });
    } catch (e) {
      _log.warning('Failed to copy image to clipboard', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to copy image')),
      );
    }
  }

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    try {
      _decodedBytes = base64Decode(widget.base64Data);
      _resolveImageDimensions();
    } catch (e) {
      _log.fine('Invalid base64 image data', e);
      _decodedBytes = null;
    }
  }

  /// Decode image dimensions so we can compute the correct layout height.
  void _resolveImageDimensions() {
    if (_decodedBytes == null) return;
    final stream = MemoryImage(_decodedBytes!).resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener(
      (ImageInfo info, bool _) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (h > 0 && mounted) {
          setState(() => _aspectRatio = w / h);
        }
        info.dispose();
      },
      onError: (exception, stackTrace) {
        _log.fine('Failed to resolve image dimensions', exception);
      },
    ));
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

    // Once we know the aspect ratio, wrap in AspectRatio so the layout
    // height matches the visually rendered height — no blank gap.
    final imageWidget = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // If dimensions are resolved, compute exact height; otherwise
        // fall back to unconstrained (first frame may flash).
        final height = _aspectRatio != null ? width / _aspectRatio! : null;
        return Image.memory(
          _decodedBytes!,
          width: width,
          height: height,
          fit: BoxFit.fitWidth,
          errorBuilder: (_, _, _) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('Failed to decode image'),
          ),
        );
      },
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: [
          GestureDetector(
            onTap: () => _showFullscreen(context),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: imageWidget,
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: AnimatedOpacity(
              opacity: (_hovering || _justCopied) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _copyToClipboard,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      _justCopied ? Icons.check : Icons.copy,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showFullscreen(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: InteractiveViewer(
            child: Image.memory(
              _decodedBytes!,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders a tool call with expandable formatted JSON arguments.
class ToolCallBlock extends StatefulWidget {
  final String name;
  final String arguments;

  const ToolCallBlock({
    super.key,
    required this.name,
    required this.arguments,
  });

  @override
  State<ToolCallBlock> createState() => _ToolCallBlockState();
}

class _ToolCallBlockState extends State<ToolCallBlock> {
  String _formattedArgs = '{}';

  @override
  void initState() {
    super.initState();
    _formatArguments();
  }

  @override
  void didUpdateWidget(covariant ToolCallBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.arguments != widget.arguments) {
      _formatArguments();
    }
  }

  void _formatArguments() {
    final raw = widget.arguments.trim();
    if (raw.isEmpty) {
      _formattedArgs = '{}';
      return;
    }
    _formattedArgs = _tryFormatJson(raw) ?? widget.arguments;
  }

  @override
  Widget build(BuildContext context) {
    final previewArgs = _formattedArgs.isEmpty
        ? '{}'
        : _formattedArgs.replaceAll('\n', ' ');

    return ExpandableBlock(
      icon: Icons.build,
      iconColor: Theme.of(context).colorScheme.tertiary,
      title: 'Tool: ${widget.name}',
      preview: previewArgs,
      initiallyExpanded: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SelectableText(
          _formattedArgs.isEmpty ? '{}' : _formattedArgs,
          style: _monospaceStyle(context),
        ),
      ),
    );
  }
}

/// Renders a tool result by iterating over its content blocks in order.
class ToolResultBlock extends StatefulWidget {
  final String toolName;
  final List<ContentBlock> resultContent;
  final String rawResponse;

  const ToolResultBlock({
    super.key,
    required this.toolName,
    required this.resultContent,
    this.rawResponse = '',
  });

  @override
  State<ToolResultBlock> createState() => _ToolResultBlockState();
}

class _ToolResultBlockState extends State<ToolResultBlock> {
  /// Pre-formatted text blocks: formatted JSON string or null (use TextBlock).
  late List<String?> _formattedTexts;
  late String? _previewText;

  @override
  void initState() {
    super.initState();
    _precompute();
  }

  @override
  void didUpdateWidget(covariant ToolResultBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resultContent != widget.resultContent) {
      _precompute();
    }
  }

  void _precompute() {
    _formattedTexts = widget.resultContent.map((block) {
      if (block is TextContentBlock) return _tryFormatJson(block.text);
      return null;
    }).toList();

    final firstText = widget.resultContent
        .whereType<TextContentBlock>()
        .firstOrNull;
    final hasImage =
        widget.resultContent.any((b) => b is ImageContentBlock);
    _previewText = firstText?.text.replaceAll('\n', ' ') ??
        (hasImage ? '[image]' : null);
  }

  @override
  Widget build(BuildContext context) {
    return ExpandableBlock(
      icon: Icons.check_circle_outline,
      iconColor: Theme.of(context).colorScheme.primary,
      title: 'Result: ${widget.toolName}',
      preview: _previewText,
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.resultContent.length; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: switch (widget.resultContent[i]) {
                TextContentBlock(:final text) => _formattedTexts[i] != null
                    ? SelectableText(
                        _formattedTexts[i]!,
                        style: _monospaceStyle(context),
                      )
                    : TextBlock(text: text),
                ImageContentBlock(:final base64Data, :final mimeType) =>
                  ImageBlock(base64Data: base64Data, mimeType: mimeType),
                _ => const SizedBox.shrink(),
              },
            ),
          if (widget.rawResponse.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: ExpandableBlock(
                icon: Icons.data_object,
                iconColor: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5),
                title: 'Raw response',
                initiallyExpanded: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SelectableText(
                    widget.rawResponse,
                    style: _monospaceStyle(context),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Renders a collapsible thinking/reasoning block.
class ThinkingBlock extends StatelessWidget {
  final String text;

  const ThinkingBlock({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final mutedColor =
        Theme.of(context).colorScheme.onSurface.withOpacity(0.5);

    return ExpandableBlock(
      icon: Icons.psychology,
      iconColor: mutedColor,
      title: 'Thinking...',
      preview: text.replaceAll('\n', ' '),
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
