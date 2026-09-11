import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Message composer: multi-line field plus send/stop button. Enter sends,
/// Shift+Enter inserts a newline.
class ChatInputArea extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isGenerating;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const ChatInputArea({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isGenerating,
    required this.onSend,
    required this.onStop,
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !isGenerating) {
      onSend();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                maxLines: 6,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: cs.outline.withValues(alpha: 0.3),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: cs.primary),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                ),
                enabled: !isGenerating,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (isGenerating)
            IconButton.filled(
              onPressed: onStop,
              icon: const Icon(Icons.stop),
              tooltip: 'Stop generation',
              style: IconButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
            )
          else
            IconButton.filled(
              onPressed: onSend,
              icon: const Icon(Icons.send),
              tooltip: 'Send (Enter)',
            ),
        ],
      ),
    );
  }
}
