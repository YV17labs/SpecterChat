import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../core/theme.dart';
import '../../../domain/models/message.dart';
import 'expandable_block.dart';
import 'image_block.dart';
import 'settings_fields.dart';
import 'word_fade_text.dart';

/// Dispatches a [ContentBlock] to its widget.
class ContentBlockWidget extends StatelessWidget {
  final ContentBlock block;
  final bool isStreaming;

  /// When false, the inner [TextBlock] disables its own selection so a
  /// surrounding `SelectionArea` can take over selection + context menu.
  final bool selectable;

  /// The block belongs to a model's reply: its images were generated.
  final bool fromModel;

  const ContentBlockWidget({
    super.key,
    required this.block,
    this.isStreaming = false,
    this.selectable = true,
    this.fromModel = false,
  });

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      TextContentBlock(:final text) => TextBlock(
        text: text,
        isStreaming: isStreaming,
        selectable: selectable,
      ),
      ImageContentBlock(
        :final attachmentId,
        :final mimeType,
        :final photoMetadata,
      ) =>
        ImageBlock(
          attachmentId: attachmentId,
          mimeType: mimeType,
          photoMetadata: photoMetadata,
          generated: fromModel,
        ),
      ToolCallContentBlock(:final name, :final arguments) => ToolCallBlock(
        name: name,
        arguments: arguments,
      ),
      final ToolResultContentBlock result => ToolResultBlock(result: result),
      ThinkingContentBlock(:final text) => ThinkingBlock(
        text: text,
        isStreaming: isStreaming,
      ),
    };
  }
}

/// Renders markdown text content.
class TextBlock extends StatelessWidget {
  final String text;
  final bool isStreaming;

  /// When false, the rendered markdown is non-selectable on its own —
  /// useful when an ancestor `SelectionArea` handles selection (and the
  /// custom context menu) at the bubble level.
  final bool selectable;

  const TextBlock({
    super.key,
    required this.text,
    this.isStreaming = false,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return MarkdownBody(
      data: text,
      selectable: selectable && !isStreaming,
      styleSheet: context.specterStyles.markdownStyleSheet,
    );
  }
}

/// A tool call, optionally together with its [result], as one expandable
/// block. Arguments are pretty-printed when they parse as JSON.
class ToolCallBlock extends StatelessWidget {
  final String name;
  final String arguments;
  final ToolResultContentBlock? result;

  const ToolCallBlock({
    super.key,
    required this.name,
    required this.arguments,
    this.result,
  });

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    final mono = context.specterStyles.monospace;

    return _JsonMemo(
      text: arguments,
      builder: (context, formatted) {
        final formattedArgs = arguments.trim().isEmpty
            ? '{}'
            : formatted ?? arguments;
        return ExpandableBlock(
          icon: Icons.build,
          iconColor: Theme.of(context).colorScheme.tertiary,
          title: 'Tool: $name',
          preview: formattedArgs.replaceAll('\n', ' '),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result != null) ...[
                  const SectionLabel('Arguments'),
                  const SizedBox(height: 4),
                ],
                SelectableText(formattedArgs, style: mono),
                if (result != null) ...[
                  const SizedBox(height: 12),
                  const SectionLabel('Result'),
                  const SizedBox(height: 4),
                  _ResultContentList(
                    blocks: result.resultContent,
                    itemPadding: const EdgeInsets.only(bottom: 6),
                  ),
                  if (result.rawResponse.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _RawResponseBlock(rawResponse: result.rawResponse),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A tool result that has no matching call in the same bubble.
class ToolResultBlock extends StatelessWidget {
  final ToolResultContentBlock result;

  const ToolResultBlock({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return ExpandableBlock(
      icon: Icons.check_circle_outline,
      iconColor: Theme.of(context).colorScheme.primary,
      title: 'Result: ${result.toolName}',
      preview: _resultPreview(result.resultContent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResultContentList(
            blocks: result.resultContent,
            itemPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          ),
          if (result.rawResponse.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _RawResponseBlock(rawResponse: result.rawResponse),
            ),
        ],
      ),
    );
  }
}

/// Collapsible thinking/reasoning block. Expanded while streaming so the
/// user sees the model work; collapses when the answer starts.
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
    final styles = context.specterStyles;
    final thinkingStyle = styles.smallMuted.copyWith(
      fontStyle: FontStyle.italic,
    );

    return ExpandableBlock(
      icon: Icons.psychology,
      iconColor: styles.textMuted,
      title: 'Thinking...',
      preview: text.replaceAll('\n', ' '),
      titleStyle: TextStyle(
        fontSize: 13,
        fontStyle: FontStyle.italic,
        color: styles.textMuted,
      ),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: styles.thinkingBlockDecoration,
      initiallyExpanded: isStreaming,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: isStreaming
            ? WordFadeText(text: text, isStreaming: true, style: thinkingStyle)
            : SelectableText(text, style: thinkingStyle),
      ),
    );
  }
}

// --- Private helpers ---------------------------------------------------

String? _tryFormatJson(String text) {
  final raw = text.trim();
  if (raw.isEmpty) return null;
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } on FormatException {
    return null;
  }
}

/// Pretty-prints [text] as JSON once per distinct input and keeps the
/// result across rebuilds. Every streaming upsert rebuilds all visible
/// bubbles, and tool payloads can be tens of KB — re-decoding them on each
/// tick is pure waste. [builder] receives `null` when [text] is not JSON.
class _JsonMemo extends StatefulWidget {
  final String text;
  final Widget Function(BuildContext context, String? formatted) builder;

  const _JsonMemo({required this.text, required this.builder});

  @override
  State<_JsonMemo> createState() => _JsonMemoState();
}

class _JsonMemoState extends State<_JsonMemo> {
  late String? _formatted = _tryFormatJson(widget.text);

  @override
  void didUpdateWidget(covariant _JsonMemo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _formatted = _tryFormatJson(widget.text);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _formatted);
}

/// First text block as a single-line preview, or `[image]` for image-only.
String? _resultPreview(List<ContentBlock> blocks) {
  final firstText = blocks.whereType<TextContentBlock>().firstOrNull;
  final hasImage = blocks.any((b) => b is ImageContentBlock);
  return firstText?.text.replaceAll('\n', ' ') ?? (hasImage ? '[image]' : null);
}

/// Renders tool-result content blocks in order: text blocks are pretty-
/// printed as JSON when parseable, images inline, unknown types dropped.
class _ResultContentList extends StatelessWidget {
  final List<ContentBlock> blocks;
  final EdgeInsetsGeometry itemPadding;

  const _ResultContentList({required this.blocks, required this.itemPadding});

  @override
  Widget build(BuildContext context) {
    final mono = context.specterStyles.monospace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          Padding(
            padding: itemPadding,
            child: switch (block) {
              TextContentBlock(:final text) => _JsonMemo(
                text: text,
                builder: (context, json) => json != null
                    ? SelectableText(json, style: mono)
                    : TextBlock(text: text),
              ),
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
      iconColor: context.specterStyles.textSubtle,
      title: 'Raw response',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SelectableText(
          rawResponse,
          style: context.specterStyles.monospace,
        ),
      ),
    );
  }
}
