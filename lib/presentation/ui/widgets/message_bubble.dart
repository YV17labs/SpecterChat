import 'package:flutter/material.dart';

import '../../../application/conversations/conversation_runs.dart';
import '../../../core/theme.dart';
import '../../../domain/chat_session_state.dart' show GenerationProgress;
import '../../../domain/models/message.dart';
import '../../../domain/models/message_stats.dart';
import '../../../domain/services/llm_hook.dart' show correctionPrefix;
import 'content_blocks.dart';
import 'local_time_text.dart';
import 'measure_text.dart';
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

  /// What the run this message answers in has cost up to and including
  /// it. Null when not applicable (user/system messages).
  final RunTotals? runTotals;

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
    this.runTotals,
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
          _MessageStats(message: message, runTotals: runTotals)
        // A user message has no measures of its own; what it weighs is
        // worth saying when it carries a picture, and only then.
        else if (isUser && message.hasImages)
          _SentWeight(message: message),
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

/// The line under a reply: ↑ 25.2K sent, ↓ 354 received, 15.7s, 25.3
/// tok/s, Σ 51.0K and Σ 20.7s for the whole run, and when it was
/// generated — each behind a small icon rather than a word, so the line
/// stays scannable at caption size. Hovering spells all of it out in
/// words, together with what the turn recorded (model, first token,
/// reasoning): the tooltip is the legend for the icons.
///
/// ↑ is what the request carried — the whole context, not just the last
/// message — ↓ what came back, and Σ the run since the user's message
/// (`cumulativeRunTotals`), on the tokens and on the time alike.
///
/// The time is the computer's: what is stored is UTC, so a conversation
/// read later, or elsewhere, still reads in the reader's time zone.
///
/// The speed is the decoding speed when the turn was measured (tokens over
/// the time after the first one), tokens over the whole duration for
/// replies written before that.
class _MessageStats extends StatelessWidget {
  final Message message;
  final RunTotals? runTotals;

  const _MessageStats({required this.message, this.runTotals});

  @override
  Widget build(BuildContext context) {
    final stats = message.generationStats;
    final prompt = message.promptTokens ?? 0;
    final tokens = message.completionTokens;
    final durationMs = message.durationMs;
    final rate = message.tokensPerSecond;
    final run = runTotals;
    final locale = systemLocaleOf(context);
    // Resolved once: this line is rebuilt on every streaming tick, for
    // every reply on screen.
    final style = context.specterStyles.caption.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
    );

    // A run with one turn in it has nothing more to total than the turn.
    final runStats = <Widget>[
      if (run != null && run.tokens > prompt + tokens)
        _Stat(Icons.functions, '${formatTokens(run.tokens)} tok', style),
      if (run != null && run.durationMs > durationMs)
        _Stat(Icons.functions, formatSeconds(run.durationMs), style),
    ];

    return Tooltip(
      message: [
        fullLocalTimestamp(message.generatedAt, locale: locale),
        if (stats != null) _details(stats),
        if (message.hasImages)
          'Weight: ${formatBytes(message.contentBytes)}, pictures included',
        if (run != null && runStats.isNotEmpty) _runDetails(run),
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 10,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (prompt > 0)
              _Stat(Icons.arrow_upward, '${formatTokens(prompt)} tok', style),
            if (tokens > 0)
              _Stat(Icons.arrow_downward, '${formatTokens(tokens)} tok', style),
            // Only when there is a picture: the weight of a text reply is
            // what its tokens already say.
            if (message.hasImages)
              _Stat(Icons.scale, formatBytes(message.contentBytes), style),
            if (durationMs > 0)
              _Stat(Icons.timer_outlined, formatSeconds(durationMs), style),
            if (rate != null)
              _Stat(Icons.bolt, '${rate.toStringAsFixed(1)} tok/s', style),
            ...runStats,
            if (_ending(stats?.outcome) case (final icon, final label)?)
              _Stat(icon, label, style),
            _Stat(
              Icons.schedule,
              shortLocalTimestamp(message.generatedAt, locale: locale),
              style,
            ),
          ],
        ),
      ),
    );
  }

  /// How the turn ended, when it did not end normally.
  static (IconData, String)? _ending(GenerationOutcome? outcome) =>
      switch (outcome) {
        GenerationOutcome.cancelled => (Icons.stop_circle_outlined, 'stopped'),
        GenerationOutcome.failed => (Icons.error_outline, 'failed'),
        GenerationOutcome.interrupted => (
          Icons.warning_amber_rounded,
          'interrupted',
        ),
        GenerationOutcome.completed || null => null,
      };

  static String _details(GenerationStats s) {
    final first = s.firstTokenMs;
    final reasoning = s.reasoningMs;
    final generation = s.generationMs;
    final rate = s.outputTokensPerSecond;
    return [
      [s.model, if (s.endpoint.isNotEmpty) s.endpoint].join(' · '),
      [
        if (s.promptTokens case final p?) 'Sent: $p tokens',
        if (first != null) 'first token after ${formatSeconds(first)}',
      ].join(' · '),
      if (reasoning != null) 'Reasoning: ${formatSeconds(reasoning)}',
      [
        switch (s.completionTokens) {
          final tokens? => 'Received: $tokens tokens',
          null => 'Received: ${s.fragments} fragments',
        },
        if (generation != null) 'in ${formatSeconds(generation)}',
        if (rate != null) '${rate.toStringAsFixed(1)} tok/s',
      ].join(' · '),
      if (s.finishReason case final reason?) 'Finish: $reason',
      if (s.retry > 0) 'Automatic retry #${s.retry}',
      if (s.error case final error?) 'Error: $error',
    ].where((l) => l.isNotEmpty).join('\n');
  }

  /// What the whole run weighs, in words — the legend for the Σ icons.
  static String _runDetails(RunTotals run) =>
      'Since your message: ${run.promptTokens} sent · '
      '${run.completionTokens} received · '
      '${run.tokens} tokens in ${formatSeconds(run.durationMs)}';
}

/// What a message the user sent weighs, under its bubble: the same
/// figure, the same icon as on a reply, so the two read alike — one is
/// what went out, the other what came back.
class _SentWeight extends StatelessWidget {
  final Message message;

  const _SentWeight({required this.message});

  @override
  Widget build(BuildContext context) {
    final style = context.specterStyles.caption.copyWith(
      color: Theme.of(
        context,
      ).colorScheme.onPrimaryContainer.withValues(alpha: 0.5),
    );
    return Tooltip(
      message:
          'Sent: ${formatBytes(message.contentBytes)}, '
          'pictures included',
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _Stat(Icons.scale, formatBytes(message.contentBytes), style),
      ),
    );
  }
}

/// One figure of the stats line: its icon and its value, as tight as the
/// text itself so a row of them reads as one line.
class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final TextStyle style;

  const _Stat(this.icon, this.label, this.style);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: style.color),
        const SizedBox(width: 3),
        Text(label, style: style),
      ],
    );
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
