import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme.dart';

/// Wraps [child] with a copy button (and an optional fork button) shown on
/// hover at the bottom-right corner.
class MessageHoverActions extends StatefulWidget {
  final String copyText;
  final VoidCallback? onFork;
  final Widget child;

  const MessageHoverActions({
    super.key,
    required this.copyText,
    required this.child,
    this.onFork,
  });

  @override
  State<MessageHoverActions> createState() => _MessageHoverActionsState();
}

class _MessageHoverActionsState extends State<MessageHoverActions> {
  bool _hovering = false;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.copyText));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = context.specterStyles.textSubtle;
    final buttonStyle = IconButton.styleFrom(
      backgroundColor: cs.surface.withValues(alpha: 0.8),
    );
    const tightConstraints = BoxConstraints(maxWidth: 24, maxHeight: 24);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          widget.child,
          if (_hovering)
            Positioned(
              bottom: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onFork != null) ...[
                    IconButton(
                      icon: Icon(Icons.fork_right, size: 14, color: iconColor),
                      onPressed: widget.onFork,
                      padding: EdgeInsets.zero,
                      constraints: tightConstraints,
                      tooltip: 'Fork to new conversation',
                      style: buttonStyle,
                    ),
                    const SizedBox(width: 4),
                  ],
                  IconButton(
                    icon: Icon(
                      _copied ? Icons.check : Icons.copy,
                      size: 14,
                      color: iconColor,
                    ),
                    onPressed: () => _copy().ignore(),
                    padding: EdgeInsets.zero,
                    constraints: tightConstraints,
                    tooltip: _copied ? 'Copied!' : 'Copy',
                    style: buttonStyle,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Wraps [child] in a [SelectionArea] whose right-click menu adds a
/// "Tell me more" item when text is selected.
class TellMoreSelectionArea extends StatefulWidget {
  final ValueChanged<String> onTellMore;
  final Widget child;

  const TellMoreSelectionArea({
    super.key,
    required this.onTellMore,
    required this.child,
  });

  @override
  State<TellMoreSelectionArea> createState() => _TellMoreSelectionAreaState();
}

class _TellMoreSelectionAreaState extends State<TellMoreSelectionArea> {
  // Context-menu builders don't receive the selection; the area reports
  // it through this callback, so keep the latest value around.
  String _selectedText = '';

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      onSelectionChanged: (content) => _selectedText = content?.plainText ?? '',
      contextMenuBuilder: (context, selectableRegionState) {
        final selected = _selectedText.trim();
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: [
            ...selectableRegionState.contextMenuButtonItems,
            if (selected.isNotEmpty)
              ContextMenuButtonItem(
                label: 'Tell me more',
                onPressed: () {
                  ContextMenuController.removeAny();
                  widget.onTellMore(selected);
                },
              ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
