import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:logging/logging.dart';

import 'expandable_block.dart';

final _log = Logger('ContentBlocks');

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
  late final Uint8List? _decodedBytes;

  @override
  void initState() {
    super.initState();
    try {
      _decodedBytes = base64Decode(widget.base64Data);
    } catch (e) {
      _log.fine('Invalid base64 image data', e);
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
      child: GestureDetector(
        onTap: () => _showFullscreen(context),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              _decodedBytes,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Failed to decode image'),
              ),
            ),
          ),
        ),
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
    try {
      final parsed = jsonDecode(raw);
      const encoder = JsonEncoder.withIndent('  ');
      _formattedArgs = encoder.convert(parsed);
    } catch (e) {
      _log.fine('Could not parse tool call arguments as JSON', e);
      _formattedArgs = widget.arguments;
    }
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

/// Renders a tool result with optional image and raw response.
class ToolResultBlock extends StatelessWidget {
  final String toolName;
  final String content;
  final String? imageBase64;
  final String? imageMimeType;
  final String rawResponse;

  const ToolResultBlock({
    super.key,
    required this.toolName,
    required this.content,
    this.imageBase64,
    this.imageMimeType,
    this.rawResponse = '',
  });

  @override
  Widget build(BuildContext context) {
    final previewText = content.isNotEmpty
        ? content.replaceAll('\n', ' ')
        : imageBase64 != null
            ? '[image]'
            : null;

    return ExpandableBlock(
      icon: Icons.check_circle_outline,
      iconColor: Theme.of(context).colorScheme.primary,
      title: 'Result: $toolName',
      preview: previewText,
      initiallyExpanded: false,
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
              child: ImageBlock(
                base64Data: imageBase64!,
                mimeType: imageMimeType ?? 'image/png',
              ),
            ),
          if (rawResponse.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: ExpandableBlock(
                icon: Icons.data_object,
                iconColor: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withOpacity(0.5),
                title: 'Raw response',
                initiallyExpanded: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SelectableText(
                    rawResponse,
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
