import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:logging/logging.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../models/message.dart';
import '../../utils/theme.dart';
import 'expandable_block.dart';
import 'word_fade_text.dart';

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
  final bool isStreaming;

  const TextBlock({
    super.key,
    required this.text,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();

    final styleSheet = context.specterStyles.markdownStyleSheet;

    if (!isStreaming) {
      return MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: styleSheet,
      );
    }

    // During streaming, split into settled (complete markdown blocks,
    // rendered formatted) and tail (paragraph-in-progress, rendered plain
    // with word-fade). Avoids reparsing an incomplete table/list/code
    // fence every tick, which would flicker.
    final (settled, tail) = _splitSettledTail(text);
    final tailStyle = styleSheet.p ?? DefaultTextStyle.of(context).style;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (settled.isNotEmpty)
          MarkdownBody(
            data: settled,
            selectable: false,
            styleSheet: styleSheet,
          ),
        if (tail.isNotEmpty)
          WordFadeText(
            text: tail,
            isStreaming: true,
            style: tailStyle,
          ),
      ],
    );
  }
}

/// Finds the last `\n\n` boundary whose prefix has balanced ``` code
/// fences — splitting inside an unclosed fence would pass malformed
/// markdown to the parser.
(String settled, String tail) _splitSettledTail(String text) {
  int boundary = text.lastIndexOf('\n\n');
  while (boundary >= 0) {
    if (_balancedFencesUpTo(text, boundary)) {
      return (text.substring(0, boundary), text.substring(boundary + 2));
    }
    boundary = text.lastIndexOf('\n\n', boundary - 1);
  }
  return ('', text);
}

bool _balancedFencesUpTo(String text, int end) {
  int count = 0;
  int i = 0;
  while (i <= end - 3) {
    if (text.codeUnitAt(i) == 0x60 &&
        text.codeUnitAt(i + 1) == 0x60 &&
        text.codeUnitAt(i + 2) == 0x60) {
      count++;
      i += 3;
    } else {
      i++;
    }
  }
  return count.isEven;
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

/// First text block as a single-line preview, or `[image]` for image-only.
String? _resultPreview(List<ContentBlock> blocks) {
  final firstText = blocks.whereType<TextContentBlock>().firstOrNull;
  final hasImage = blocks.any((b) => b is ImageContentBlock);
  return firstText?.text.replaceAll('\n', ' ') ??
      (hasImage ? '[image]' : null);
}

/// Renders tool-result content blocks in order: text blocks are pretty-
/// printed as JSON when parseable, images inline, unknown types dropped.
class _ResultContentList extends StatefulWidget {
  final List<ContentBlock> blocks;
  final EdgeInsetsGeometry itemPadding;

  const _ResultContentList({
    required this.blocks,
    required this.itemPadding,
  });

  @override
  State<_ResultContentList> createState() => _ResultContentListState();
}

class _ResultContentListState extends State<_ResultContentList> {
  late List<String?> _formattedTexts;

  @override
  void initState() {
    super.initState();
    _precompute();
  }

  @override
  void didUpdateWidget(covariant _ResultContentList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blocks != widget.blocks) _precompute();
  }

  void _precompute() {
    _formattedTexts = widget.blocks.map((b) {
      if (b is TextContentBlock) return _tryFormatJson(b.text);
      return null;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.blocks.length; i++)
          Padding(
            padding: widget.itemPadding,
            child: switch (widget.blocks[i]) {
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
      ],
    );
  }
}

class _RawResponseBlock extends StatelessWidget {
  final String rawResponse;

  const _RawResponseBlock({required this.rawResponse});

  @override
  Widget build(BuildContext context) {
    return ExpandableBlock(
      icon: Icons.data_object,
      iconColor:
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
      title: 'Raw response',
      initiallyExpanded: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SelectableText(
          rawResponse,
          style: _monospaceStyle(context),
        ),
      ),
    );
  }
}

/// Renders a tool call together with its result in a single expandable block.
class ToolCallWithResultBlock extends StatefulWidget {
  final String name;
  final String arguments;
  final List<ContentBlock> resultContent;
  final String rawResponse;

  const ToolCallWithResultBlock({
    super.key,
    required this.name,
    required this.arguments,
    required this.resultContent,
    this.rawResponse = '',
  });

  @override
  State<ToolCallWithResultBlock> createState() =>
      _ToolCallWithResultBlockState();
}

class _ToolCallWithResultBlockState extends State<ToolCallWithResultBlock> {
  String _formattedArgs = '{}';

  @override
  void initState() {
    super.initState();
    _formatArgs();
  }

  @override
  void didUpdateWidget(covariant ToolCallWithResultBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.arguments != widget.arguments) _formatArgs();
  }

  void _formatArgs() {
    final raw = widget.arguments.trim();
    _formattedArgs =
        raw.isEmpty ? '{}' : (_tryFormatJson(raw) ?? widget.arguments);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _formattedArgs.replaceAll('\n', ' ');

    return ExpandableBlock(
      icon: Icons.build,
      iconColor: Theme.of(context).colorScheme.tertiary,
      title: 'Tool: ${widget.name}',
      preview: preview,
      initiallyExpanded: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ToolSectionLabel(label: 'Arguments'),
            const SizedBox(height: 4),
            SelectableText(
              _formattedArgs,
              style: _monospaceStyle(context),
            ),
            const SizedBox(height: 12),
            const _ToolSectionLabel(label: 'Result'),
            const SizedBox(height: 4),
            _ResultContentList(
              blocks: widget.resultContent,
              itemPadding: const EdgeInsets.only(bottom: 6),
            ),
            if (widget.rawResponse.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _RawResponseBlock(rawResponse: widget.rawResponse),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolSectionLabel extends StatelessWidget {
  final String label;

  const _ToolSectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: Theme.of(context)
            .colorScheme
            .onSurface
            .withValues(alpha: 0.5),
      ),
    );
  }
}

/// Renders a tool result as a standalone expandable block.
class ToolResultBlock extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ExpandableBlock(
      icon: Icons.check_circle_outline,
      iconColor: Theme.of(context).colorScheme.primary,
      title: 'Result: $toolName',
      preview: _resultPreview(resultContent),
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResultContentList(
            blocks: resultContent,
            itemPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          ),
          if (rawResponse.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _RawResponseBlock(rawResponse: rawResponse),
            ),
        ],
      ),
    );
  }
}

/// Renders a collapsible thinking/reasoning block.
class ThinkingBlock extends StatelessWidget {
  final String text;
  final bool isStreaming;

  const ThinkingBlock({
    super.key,
    required this.text,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final mutedColor =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);

    final thinkingStyle = TextStyle(
      fontSize: 12,
      fontStyle: FontStyle.italic,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
    );

    final Widget body = isStreaming
        ? WordFadeText(text: text, isStreaming: true, style: thinkingStyle)
        : SelectableText(text, style: thinkingStyle);

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
      decoration: context.specterStyles.thinkingBlockDecoration,
      initiallyExpanded: isStreaming,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: body,
      ),
    );
  }
}
