import 'package:flutter/services.dart';

/// Whether the platform's primary shortcut modifier (⌘ on macOS, Ctrl
/// elsewhere) is held. Both are accepted everywhere so a shortcut works
/// the same on every desktop.
bool get isPrimaryModifierPressed {
  final kb = HardwareKeyboard.instance;
  return kb.isMetaPressed || kb.isControlPressed;
}
