import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/message.dart';
import '../../utils/theme.dart';
import 'expandable_block.dart';
import 'image_block.dart';
import 'word_fade_text.dart';

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

    return MarkdownBody(
      data: text,
      selectable: !isStreaming,
      styleSheet: styleSheet,
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
              ImageContentBlock(:final attachmentId, :final mimeType) =>
                ImageBlock(attachmentId: attachmentId, mimeType: mimeType),
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
