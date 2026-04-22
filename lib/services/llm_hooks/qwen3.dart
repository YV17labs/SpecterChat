/// Hooks for Qwen 3.x models (currently 3.5 and 3.6).
///
/// Known quirks shared across the family:
/// - Frequently hallucinates tool calls as raw XML (`<tool_call>`,
///   `<function=…>`) in content or thinking output instead of using
///   the native tool-call mechanism.
/// - Occasionally finishes streaming content without emitting the
///   terminating `[DONE]` marker or closing the HTTP connection, which
///   hangs the client until the user forces a new turn.
library;
import 'llm_hook.dart';

final _patterns = [
  RegExp(r'<tool_call>', caseSensitive: false),
  RegExp(r'<function=\w+', caseSensitive: false),
  RegExp(r'<invoke\s', caseSensitive: false),
];

class Qwen3Hook extends LlmHook {
  @override
  // Matches naming variants seen in the wild: "qwen3.5", "qwen3-5",
  // "qwen3_5", "Qwen3-5-27B-Q5_K_M", etc. — any separator (or none)
  // between "qwen3" and the minor-version digit.
  final modelPattern = RegExp(r'qwen3[.\-_]?(5|6)', caseSensitive: false);

  @override
  bool detectHallucination(String text) {
    return _patterns.any((p) => p.hasMatch(text));
  }

  @override
  final hallucinationCorrection =
      'Your previous response contained raw XML tool-call syntax '
      '(<tool_call>, <function=…>) instead of an actual tool call. '
      'This is not valid. Please answer the question directly in plain '
      'text, or use the provided tools properly via function calling.';

  // 8s covers the worst legitimate inter-token gap (~2-3s) with
  // headroom; also applies before the first chunk, so a very cold
  // model under a huge prompt could trip it — raise if that happens
  // in practice.
  @override
  final streamInactivityTimeout = const Duration(seconds: 8);

  @override
  final streamStallCorrection =
      'Your previous response did not terminate properly — the stream '
      'went silent without closing. If your answer was actually complete, '
      'reply with a single period (".") and nothing else. Otherwise, '
      'continue exactly where you left off without repeating what you '
      'already said.';
}

/// Singleton instance registered in the hook registry.
final qwen3Hook = Qwen3Hook();
