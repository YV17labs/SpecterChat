import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pending text to append to the chat input box.
///
/// Producers (MCP prompt/resource rows, "Tell me more", fork) set it; the
/// chat input listens, appends the text to its controller, then calls
/// [ChatInputInjection.consume]. This one-shot channel avoids coupling
/// sidebar widgets to the chat input's controller.
final chatInputInjectionProvider =
    NotifierProvider<ChatInputInjection, String?>(ChatInputInjection.new);

class ChatInputInjection extends Notifier<String?> {
  @override
  String? build() => null;

  void inject(String text) => state = text;

  /// Reset so back-to-back identical injections re-trigger listeners.
  void consume() => state = null;
}
