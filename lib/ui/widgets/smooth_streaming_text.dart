import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Reveals [text] character by character so streamed LLM output feels
/// fluid, instead of arriving in the chunks produced by the DB
/// persistence throttle.
///
/// Tuned for soft, even pacing: keeps a ~400ms backlog so the reveal
/// rate stays steady even when the upstream chunks arrive in bursts.
class SmoothStreamingText extends StatefulWidget {
  final String text;
  final bool isStreaming;
  final Widget Function(BuildContext context, String visibleText) builder;

  const SmoothStreamingText({
    super.key,
    required this.text,
    required this.isStreaming,
    required this.builder,
  });

  @override
  State<SmoothStreamingText> createState() => _SmoothStreamingTextState();
}

class _SmoothStreamingTextState extends State<SmoothStreamingText>
    with SingleTickerProviderStateMixin {
  static const double _baseRate = 80.0;
  static const double _maxStreamingRate = 260.0;
  static const double _flushRate = 1500.0;
  static const double _targetLatencySeconds = 0.45;

  /// Caps rebuilds at ~22Hz so expensive children like MarkdownBody
  /// don't reparse every frame.
  static const Duration _minRebuildInterval = Duration(milliseconds: 45);

  late final Ticker _ticker;
  Duration? _lastTickElapsed;
  Duration _lastRebuildElapsed = Duration.zero;
  int _visibleCount = 0;
  double _revealRemainder = 0.0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _visibleCount = widget.isStreaming ? 0 : widget.text.length;
    _maybeStartTicker();
  }

  @override
  void didUpdateWidget(covariant SmoothStreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Detect replaced (not just extended) target by comparing the
    // already-revealed prefix — handles shrink AND same-length swaps.
    final revealed = _visibleCount <= oldWidget.text.length
        ? oldWidget.text.substring(0, _visibleCount)
        : oldWidget.text;
    if (!widget.text.startsWith(revealed)) {
      _visibleCount = widget.isStreaming ? 0 : widget.text.length;
      _revealRemainder = 0.0;
    } else if (_visibleCount > widget.text.length) {
      _visibleCount = widget.text.length;
    }

    _maybeStartTicker();
  }

  void _maybeStartTicker() {
    if (_visibleCount < widget.text.length && !_ticker.isActive) {
      _lastTickElapsed = null;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final last = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (last == null) return;

    final dt = (elapsed - last).inMicroseconds / 1e6;
    if (dt <= 0) return;

    final targetLen = widget.text.length;
    final pending = targetLen - _visibleCount;

    if (pending <= 0) {
      _ticker.stop();
      _lastTickElapsed = null;
      return;
    }

    final rate = widget.isStreaming
        ? (pending / _targetLatencySeconds).clamp(_baseRate, _maxStreamingRate)
        : _flushRate;

    final advance = dt * rate + _revealRemainder;
    final wholeChars = advance.floor();
    _revealRemainder = advance - wholeChars;
    if (wholeChars <= 0) return;

    final newVisible = (_visibleCount + wholeChars).clamp(0, targetLen);
    final reachedEnd = newVisible >= targetLen;

    if (!reachedEnd && (elapsed - _lastRebuildElapsed) < _minRebuildInterval) {
      _visibleCount = newVisible;
      return;
    }

    _lastRebuildElapsed = elapsed;
    setState(() => _visibleCount = newVisible);

    if (reachedEnd) {
      _ticker.stop();
      _lastTickElapsed = null;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleCount >= widget.text.length
        ? widget.text
        : widget.text.substring(0, _visibleCount);
    return widget.builder(context, visible);
  }
}
