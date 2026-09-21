import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../application/images/pending_image.dart';
import '../widgets/keyboard.dart';
import 'pending_image_strip.dart';

/// Message composer: pending-image strip, multi-line field, attach button
/// and send/stop button. Enter sends, Shift+Enter inserts a newline,
/// Cmd/Ctrl+V with an image on the clipboard attaches it.
class ChatInputArea extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isGenerating;
  final List<PendingImage> pendingImages;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttach;
  final ValueChanged<String> onRemoveImage;

  /// Opens the annotation editor for a pending image.
  final ValueChanged<String>? onEditImage;

  /// Called on Cmd/Ctrl+V. The handler decides between attaching an
  /// image and pasting text; the key event is always consumed.
  final VoidCallback onPaste;

  const ChatInputArea({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isGenerating,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onRemoveImage,
    required this.onPaste,
    this.onEditImage,
    this.pendingImages = const [],
  });

  static bool _isPasteChord(KeyEvent event) =>
      event.logicalKey == LogicalKeyboardKey.keyV && isPrimaryModifierPressed;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !isGenerating) {
      onSend();
      return KeyEventResult.handled;
    }
    if (_isPasteChord(event) && !isGenerating) {
      onPaste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PendingImageStrip(
            images: pendingImages,
            onRemove: onRemoveImage,
            onEdit: onEditImage,
            enabled: !isGenerating,
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                onPressed: isGenerating ? null : onAttach,
                icon: const Icon(Icons.attach_file),
                tooltip: 'Attach image',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    maxLines: 6,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: pendingImages.isEmpty
                          ? 'Type a message...'
                          : 'Describe what to do with the image...',
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
        ],
      ),
    );
  }
}
