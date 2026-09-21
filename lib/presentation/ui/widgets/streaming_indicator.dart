import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../domain/chat_session_state.dart' show GenerationProgress;

/// Thin progress bar plus caption for a long-running server step
/// ("Generating 12/40"). Indeterminate when the server gave no numbers.
class GenerationProgressBar extends StatelessWidget {
  final GenerationProgress progress;

  const GenerationProgressBar({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 3,
            ),
          ),
          const SizedBox(height: 4),
          Text(progress.label, style: styles.caption),
        ],
      ),
    );
  }
}

/// Three pulsing dots shown while an assistant turn is streaming.
class StreamingIndicator extends StatelessWidget {
  const StreamingIndicator({super.key});

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
              child: _Dot(delay: Duration(milliseconds: i * 200)),
            );
          }),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final Duration delay;
  const _Dot({required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _startDelay;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    // Stagger the three dots. Held in a field so an unmount before the
    // delay elapses cancels it instead of leaking a timer.
    _startDelay = Timer(widget.delay, () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _startDelay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onSurface.withValues(alpha: 0.3 + _controller.value * 0.4),
          ),
        );
      },
    );
  }
}
