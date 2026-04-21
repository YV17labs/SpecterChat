import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Streams text word-by-word with a soft per-word fade-in.
///
/// Each whitespace-separated token fades from transparent to its final
/// color over [_fadeDuration]. Emission rate adapts to the buffer
/// backlog: when the upstream model streams fast, more tokens are
/// mid-fade simultaneously — that produces a bigger wave. Each
/// individual token still fades over the same duration, so the softness
/// per word stays constant regardless of model speed.
class WordFadeText extends StatefulWidget {
  final String text;
  final bool isStreaming;
  final TextStyle style;

  const WordFadeText({
    super.key,
    required this.text,
    required this.isStreaming,
    required this.style,
  });

  @override
  State<WordFadeText> createState() => _WordFadeTextState();
}

class _WordFadeTextState extends State<WordFadeText>
    with SingleTickerProviderStateMixin {
  static const double _baseRate = 12.0;
  static const double _maxRate = 45.0;
  static const double _flushRate = 250.0;
  static const int _reliefThreshold = 4;
  static const int _maxPending = 24;
  static const Duration _fadeDuration = Duration(milliseconds: 320);

  static final _tokenPattern = RegExp(r'\S+\s*|\s+');

  late final Ticker _ticker;
  Duration _now = Duration.zero;

  List<String> _tokens = const [];
  final List<Duration> _emitTimes = [];
  double _emitRemainder = 0;

  /// First index in [_emitTimes] whose fade has NOT yet completed.
  /// Tokens below this are fully opaque and can be rendered as a single
  /// cached span, avoiding O(N) TextSpan rebuilds per frame.
  int _settledIdx = 0;
  String? _settledText;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _tokens = _tokenize(widget.text);
    if (!widget.isStreaming) {
      _emitTimes.addAll(
        List.filled(_tokens.length, Duration.zero),
      );
      _settledIdx = _tokens.length;
    } else {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(covariant WordFadeText oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newTokens = _tokenize(widget.text);
    final emitted = _emitTimes.length;

    bool canExtend = emitted <= newTokens.length;
    if (canExtend) {
      for (int i = 0; i < emitted; i++) {
        if (_tokens[i] != newTokens[i]) {
          canExtend = false;
          break;
        }
      }
    }

    if (!canExtend) {
      _tokens = newTokens;
      _emitTimes.clear();
      _emitRemainder = 0;
      _settledIdx = 0;
      _settledText = null;
      if (!widget.isStreaming) {
        _emitTimes.addAll(List.filled(newTokens.length, Duration.zero));
        _settledIdx = newTokens.length;
      }
    } else {
      _tokens = newTokens;
    }

    _maybeStartTicker();
  }

  void _maybeStartTicker() {
    if (_ticker.isActive) return;
    if (_emitTimes.length < _emittableCount() || _hasInFlightFade()) {
      _ticker.start();
    }
  }

  int _emittableCount() {
    if (!widget.isStreaming) return _tokens.length;
    // Keep the last token in reserve until more text arrives — its
    // trailing whitespace may still grow, and re-emitting it would
    // mutate an already-animated span.
    return _tokens.isEmpty ? 0 : _tokens.length - 1;
  }

  bool _hasInFlightFade() {
    // Only scan from _settledIdx — earlier tokens are already fully
    // faded by construction.
    final fadeMicros = _fadeDuration.inMicroseconds;
    for (int i = _settledIdx; i < _emitTimes.length; i++) {
      if ((_now - _emitTimes[i]).inMicroseconds < fadeMicros) return true;
    }
    return false;
  }

  /// Advances [_settledIdx] past any tokens whose fade has completed.
  /// Returns true if the index advanced (cache needs rebuilding).
  bool _advanceSettled() {
    final fadeMicros = _fadeDuration.inMicroseconds;
    final before = _settledIdx;
    while (_settledIdx < _emitTimes.length &&
        (_now - _emitTimes[_settledIdx]).inMicroseconds >= fadeMicros) {
      _settledIdx++;
    }
    return _settledIdx != before;
  }

  void _onTick(Duration elapsed) {
    final prev = _now;
    _now = elapsed;
    final dt = (elapsed - prev).inMicroseconds / 1e6;
    if (dt < 0) return;

    final emittable = _emittableCount();
    final pending = emittable - _emitTimes.length;

    final double rate;
    if (!widget.isStreaming) {
      rate = _flushRate;
    } else if (pending <= _reliefThreshold) {
      rate = _baseRate;
    } else {
      final t = ((pending - _reliefThreshold) /
              (_maxPending - _reliefThreshold))
          .clamp(0.0, 1.0);
      rate = _baseRate + t * (_maxRate - _baseRate);
    }

    final advance = dt * rate + _emitRemainder;
    final emitCount = advance.floor();
    _emitRemainder = advance - emitCount;

    bool changed = false;
    if (emitCount > 0 && pending > 0) {
      final n = emitCount < pending ? emitCount : pending;
      for (int i = 0; i < n; i++) {
        _emitTimes.add(_now);
      }
      changed = true;
    }

    // Promote newly-settled tokens into the cached span.
    if (_advanceSettled()) {
      _settledText = null; // invalidate cache; build() recomputes
      changed = true;
    }

    final inFlight = _hasInFlightFade();
    if (_emitTimes.length >= emittable && !inFlight) {
      _ticker.stop();
      if (changed) setState(() {});
      return;
    }

    // In-flight tokens change opacity every frame, so always rebuild
    // while any fade is active.
    if (changed || inFlight) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_emitTimes.isEmpty) return const SizedBox.shrink();

    final baseColor = widget.style.color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF000000);
    final baseAlpha = baseColor.a;
    final fadeMicros = _fadeDuration.inMicroseconds;
    final emitted = _emitTimes.length;

    final spans = <TextSpan>[];

    // Settled prefix: one span, cached across frames. Only the in-flight
    // tail is rebuilt each frame.
    if (_settledIdx > 0) {
      _settledText ??= _tokens.take(_settledIdx).join();
      spans.add(TextSpan(text: _settledText));
    }

    for (int i = _settledIdx; i < emitted; i++) {
      final elapsed = (_now - _emitTimes[i]).inMicroseconds;
      final raw = fadeMicros > 0
          ? (elapsed / fadeMicros).clamp(0.0, 1.0)
          : 1.0;
      final eased = Curves.easeOut.transform(raw);
      final color = baseColor.withValues(alpha: eased * baseAlpha);
      spans.add(TextSpan(
        text: _tokens[i],
        style: widget.style.copyWith(color: color),
      ));
    }

    return RichText(text: TextSpan(style: widget.style, children: spans));
  }

  static List<String> _tokenize(String text) {
    if (text.isEmpty) return const [];
    return _tokenPattern.allMatches(text).map((m) => m.group(0)!).toList();
  }
}
