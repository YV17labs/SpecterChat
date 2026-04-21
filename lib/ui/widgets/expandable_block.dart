import 'package:flutter/material.dart';

import '../../utils/theme.dart';

/// Reusable expandable container for tool calls, results, and thinking blocks.
class ExpandableBlock extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final TextStyle? titleStyle;
  final String? preview;
  final bool initiallyExpanded;
  final Widget child;
  final EdgeInsetsGeometry margin;
  final BoxDecoration? decoration;

  const ExpandableBlock({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    this.titleStyle,
    this.preview,
    this.initiallyExpanded = false,
    required this.child,
    this.margin = const EdgeInsets.symmetric(vertical: 4),
    this.decoration,
  });

  @override
  State<ExpandableBlock> createState() => _ExpandableBlockState();
}

class _ExpandableBlockState extends State<ExpandableBlock> {
  static const _animDuration = Duration(milliseconds: 260);
  static const _animCurve = Curves.easeInOut;

  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant ExpandableBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Allow callers (e.g. thinking block) to steer the state by flipping
    // `initiallyExpanded` at runtime — the flag drives the collapse when
    // streaming ends. User taps still override at any time.
    if (widget.initiallyExpanded != oldWidget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final decoration =
        widget.decoration ?? context.specterStyles.expandableBlockDecoration;

    return Container(
      margin: widget.margin,
      decoration: decoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(widget.icon, size: 14, color: widget.iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: widget.titleStyle ??
                                TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: widget.iconColor,
                                ),
                          ),
                        ),
                        if (widget.preview != null &&
                            widget.preview!.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: AnimatedOpacity(
                              opacity: _expanded ? 0.0 : 1.0,
                              duration: _animDuration,
                              curve: _animCurve,
                              child: ShaderMask(
                                shaderCallback: (bounds) => LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.onSurface,
                                    Colors.transparent,
                                  ],
                                  stops: const [0.5, 1.0],
                                ).createShader(bounds),
                                blendMode: BlendMode.dstIn,
                                child: Text(
                                  widget.preview!,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0.0,
                    duration: _animDuration,
                    curve: _animCurve,
                    child: const Icon(Icons.expand_more, size: 18),
                  ),
                ],
              ),
            ),
          ),
          ClipRect(
            child: AnimatedAlign(
              alignment: Alignment.topLeft,
              heightFactor: _expanded ? 1.0 : 0.0,
              duration: _animDuration,
              curve: _animCurve,
              child: AnimatedOpacity(
                opacity: _expanded ? 1.0 : 0.0,
                duration: _animDuration,
                curve: _animCurve,
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
