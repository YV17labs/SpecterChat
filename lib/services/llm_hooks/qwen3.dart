/// Hooks for Qwen 3.x models (currently 3.5 and 3.6).
///
/// Known quirk: Qwen 3.x frequently hallucinates tool calls as raw XML
/// (`<tool_call>`, `<function=…>`) in content or thinking output instead
/// of using the native tool-call mechanism.
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

  // Kept deliberately neutral: do NOT echo the broken markup
  // (`<tool_call>`, `<function=…>`) back to the model — re-injecting
  // those tokens primes the same hallucination on the next turn and
  // can re-trigger our own detector in a loop.
  @override
  final hallucinationCorrection =
      'That last attempt did not produce a valid tool call and was '
      'discarded. Please try again: either answer in plain text, or '
      'invoke a tool via the proper function-calling mechanism.';
}

/// Singleton instance registered in the hook registry.
final qwen3Hook = Qwen3Hook();
