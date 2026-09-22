import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../domain/chat_session_state.dart' show GenerationProgress;
import '../../../domain/models/message.dart';
import '../../../domain/models/message_stats.dart';
import '../../../domain/services/llm_hook.dart' show correctionPrefix;
import 'content_blocks.dart';
import 'local_time_text.dart';
import 'message_hover_actions.dart';
import 'streaming_indicator.dart';

// Auto-correction bubble colors (amber at various alphas).
const _correctionBg = Color(0x26FFC107);
const _correctionBorder = Color(0x66FFC107);
const _correctionAvatarBg = Color(0x33FFC107);
const _correctionAccent = Color(0xFFFFCA28);

/// One message (plus the tool-result messages that answer it) as a bubble.
class MessageBubble extends StatelessWidget {
  final Message message;
  final List<Message> toolResults;

  /// Cumulative assistant-turn duration (ms) up to and including this
  /// message. Null when not applicable (user/system messages).
  final int? cumulativeDurationMs;

  /// Invoked when the user picks "Tell me more" from the right-click menu
  /// on a selection inside an assistant message. Null disables the item.
  final ValueChanged<String>? onTellMore;

  /// Invoked when the user clicks the "fork" hover button on a user
  /// message — creates a new conversation seeded with that message.
  /// Null hides the button.
  final ValueChanged<String>? onFork;

  /// Server-reported progress for this (streaming) message, if any. Shown
  /// in place of the typing dots while an image is being generated.
  final GenerationProgress? progress;

  const MessageBubble({
    super.key,
    required this.message,
    this.toolResults = const [],
    this.cumulativeDurationMs,
    this.onTellMore,
    this.onFork,
    this.progress,
  });

  bool get _isUser => message.role == MessageRole.user;

  /// Whether this message is an auto-injected hallucination correction.
  bool get _isAutoCorrection =>
      _isUser && message.plainText.startsWith(correctionPrefix);

  Map<String, ToolResultContentBlock> _indexToolResults() => {
    for (final toolMsg in toolResults)
      for (final block in toolMsg.content)
        if (block is ToolResultContentBlock) block.toolCallId: block,
  };

  @override
  Widget build(BuildContext context) {
    final isUser = _isUser;
    final isAutoCorrection = _isAutoCorrection;
    final resultsByCallId = _indexToolResults();
    final maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.65;
    final cs = Theme.of(context).colorScheme;

    // When the bubble is wrapped in our SelectionArea, inner widgets must
    // NOT be self-selectable: a SelectableText would intercept right-click
    // and show its own toolbar (Copy only), bypassing the SelectionArea's
    // contextMenuBuilder where "Tell me more" lives.
    final tellMore = onTellMore;
    final wrappedInSelectionArea =
        !isUser && !message.isStreaming && tellMore != null;

    // Tool-call ids whose result renders inline with the call.
    final consumedIds = <String>{
      for (final block in message.content)
        if (block is ToolCallContentBlock &&
            resultsByCallId.containsKey(block.id))
          block.id,
    };

    Widget childFor(ContentBlock block) {
      if (block is ToolCallContentBlock) {
        final result = resultsByCallId[block.id];
        return BlockFadeIn(
          child: ToolCallBlock(
            name: block.name,
            arguments: block.arguments,
            result: result,
          ),
        );
      }
      final built = ContentBlockWidget(
        block: block,
        isStreaming: message.isStreaming,
        selectable: !wrappedInSelectionArea,
      );
      // Markdown text appears in place as it streams; every other block
      // type fades in as a whole on first appearance.
      if (block is TextContentBlock) return built;
      return BlockFadeIn(child: built);
    }

    // Tool-result blocks not paired with a call in the assistant message.
    // Rare, but kept visible rather than silently dropped.
    final orphanResultGroups = <List<ContentBlock>>[];
    for (final toolMsg in toolResults) {
      final orphans = [
        for (final block in toolMsg.content)
          if (block is! ToolResultContentBlock ||
              !consumedIds.contains(block.toolCallId))
            block,
      ];
      if (orphans.isNotEmpty) orphanResultGroups.add(orphans);
    }

    final alignEnd = isUser && !isAutoCorrection;

    Widget body = Column(
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
        for (final (i, block) in message.content.indexed) ...[
          // Images sit flush against markdown text otherwise; give them air
          // on both sides so a caption + picture reads as two elements.
          if (i > 0 &&
              (block is ImageContentBlock ||
                  message.content[i - 1] is ImageContentBlock))
            const SizedBox(height: 10),
          childFor(block),
        ],
        if (message.isStreaming)
          if (progress case final p?)
            GenerationProgressBar(progress: p)
          else
            const StreamingIndicator(),
        if (!message.isStreaming &&
            message.role == MessageRole.assistant &&
            (message.completionTokens > 0 || message.stats != null))
          _MessageStats(
            message: message,
            cumulativeDurationMs: cumulativeDurationMs,
          ),
      ],
    );
    if (wrappedInSelectionArea) {
      body = TellMoreSelectionArea(onTellMore: tellMore, child: body);
    }

    Widget bubble = Container(
      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
      // Pin width to max while the assistant streams so the bubble doesn't
      // widen character-by-character — that triggers text reflow (words
      // re-wrapping from the start of a line onto the end of the previous
      // one), which reads as "text sliding right-to-left".
      width: (!isUser && message.isStreaming) ? maxBubbleWidth : null,
      decoration: BoxDecoration(
        color: isAutoCorrection
            ? _correctionBg
            : isUser
            ? cs.primaryContainer
            : cs.surfaceContainerHigh,
        border: isAutoCorrection ? Border.all(color: _correctionBorder) : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: alignEnd ? const Radius.circular(16) : Radius.zero,
          bottomRight: alignEnd ? Radius.zero : const Radius.circular(16),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topLeft,
        child: body,
      ),
    );
    bubble = _withHoverActions(bubble);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: alignEnd
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
                bubble,
                for (final orphans in orphanResultGroups)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                      decoration:
                          context.specterStyles.toolResultGroupDecoration,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final block in orphans)
                            ContentBlockWidget(block: block),
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

  /// Adds copy (and fork, for user messages) hover buttons when the message
  /// has real text — skips assistant turns that are pure thinking + tools.
  Widget _withHoverActions(Widget child) {
    final isCompletedAssistant =
        message.role == MessageRole.assistant && !message.isStreaming;
    if (!_isUser && !isCompletedAssistant) return child;

    final copyText = message.content
        .whereType<TextContentBlock>()
        .map((b) => b.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n');
    if (copyText.isEmpty) return child;

    final fork = onFork;
    return MessageHoverActions(
      copyText: copyText,
      onFork: _isUser && fork != null ? () => fork(copyText) : null,
      child: child,
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
        child: Icon(Icons.auto_fix_high, size: 18, color: _correctionAccent),
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

/// "354 tokens · 15.7s · 22.6 tok/s · Σ 20.7s · 14:32" under a reply;
/// hovering shows what the turn recorded (model, prompt, first token,
/// reasoning) and the whole date it was generated on.
///
/// The time is the computer's: what is stored is UTC, so a conversation
/// read later, or elsewhere, still reads in the reader's time zone.
///
/// The speed is the decoding speed when the turn was measured (tokens over
/// the time after the first one), tokens over the whole duration for
/// replies written before that.
class _MessageStats extends StatelessWidget {
  final Message message;
  final int? cumulativeDurationMs;

  const _MessageStats({required this.message, this.cumulativeDurationMs});

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  @override
  Widget build(BuildContext context) {
    final stats = message.generationStats;
    final tokens = message.completionTokens;
    final durationMs = message.durationMs;
    final parts = <String>[
      if (tokens > 0) '$tokens tokens',
      if (durationMs > 0) _seconds(durationMs),
    ];
    final rate = message.tokensPerSecond;
    if (rate != null) parts.add('${rate.toStringAsFixed(1)} tok/s');
    final cumulative = cumulativeDurationMs;
    if (cumulative != null && cumulative > durationMs && cumulative > 0) {
      parts.add('Σ ${_seconds(cumulative)}');
    }
    final ending = switch (stats?.outcome) {
      GenerationOutcome.cancelled => 'stopped',
      GenerationOutcome.failed => 'failed',
      GenerationOutcome.interrupted => 'interrupted',
      GenerationOutcome.completed || null => null,
    };
    if (ending != null) parts.add(ending);
    final locale = systemLocaleOf(context);
    parts.add(shortLocalTimestamp(message.generatedAt, locale: locale));

    return Tooltip(
      message: [
        fullLocalTimestamp(message.generatedAt, locale: locale),
        if (stats != null) _details(stats),
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          parts.join('  ·  '),
          style: context.specterStyles.caption.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }

  static String _details(GenerationStats s) {
    final first = s.firstTokenMs;
    final reasoning = s.reasoningMs;
    final generation = s.generationMs;
    final rate = s.outputTokensPerSecond;
    return [
      [s.model, if (s.endpoint.isNotEmpty) s.endpoint].join(' · '),
      [
        if (s.promptTokens case final p?) 'Prompt: $p tokens',
        if (first != null) 'first token after ${_seconds(first)}',
      ].join(' · '),
      if (reasoning != null) 'Reasoning: ${_seconds(reasoning)}',
      [
        switch (s.completionTokens) {
          final tokens? => 'Output: $tokens tokens',
          null => 'Output: ${s.fragments} fragments',
        },
        if (generation != null) 'in ${_seconds(generation)}',
        if (rate != null) '${rate.toStringAsFixed(1)} tok/s',
      ].join(' · '),
      if (s.finishReason case final reason?) 'Finish: $reason',
      if (s.retry > 0) 'Automatic retry #${s.retry}',
      if (s.error case final error?) 'Error: $error',
    ].where((l) => l.isNotEmpty).join('\n');
  }
}

/// One-shot fade-in wrapper for container blocks (tool calls, thinking
/// boxes, images) so they appear softly instead of popping in. The
/// tween only animates on first build; once mounted, rebuilds of the
/// same widget keep it at full opacity.
class BlockFadeIn extends StatelessWidget {
  final Widget child;
  const BlockFadeIn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      tween: Tween(begin: 0.0, end: 1.0),
      // Skip the Opacity (and its saveLayer) once fully faded in — this
      // is the steady state after the one-shot animation.
      builder: (context, value, child) =>
          value >= 1.0 ? child! : Opacity(opacity: value, child: child),
      child: child,
    );
  }
}
