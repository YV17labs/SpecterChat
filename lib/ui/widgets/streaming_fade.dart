import 'package:flutter/material.dart';

/// Soft trailing-edge brightness ramp for streaming content: the bottom
/// [fadeHeight] pixels ramp from transparent to fully opaque via a smooth
/// non-linear curve so glyphs visibly brighten up to their original color
/// as new text pushes them upward. Caps at alpha 1.0 — never overshoots.
/// Pixel-level, so it works with any child (markdown, text, code).
class StreamingFade extends StatelessWidget {
  final bool active;
  final double fadeHeight;
  final Widget child;

  const StreamingFade({
    super.key,
    required this.active,
    required this.child,
    this.fadeHeight = 72,
  });

  @override
  Widget build(BuildContext context) {
    if (!active) return child;

    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final h = bounds.height;
        if (h <= 0) {
          return const LinearGradient(
            colors: [Colors.white, Colors.white],
          ).createShader(bounds);
        }
        // Cap the ramp zone to 60% of the widget height so short blocks
        // still keep a readable top portion.
        final fade = fadeHeight.clamp(0.0, h * 0.6);
        final t = (h - fade) / h;
        // Ease-in curve: opacity rises slowly at the bottom, then faster
        // as it approaches full. Gives the "lighting up" progression.
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, t, t + (1 - t) * 0.45, t + (1 - t) * 0.78, 1.0],
          colors: const [
            Colors.white,
            Colors.white,
            Color(0xE6FFFFFF), // ~90%
            Color(0x80FFFFFF), // ~50%
            Color(0x00FFFFFF), // 0%
          ],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}
