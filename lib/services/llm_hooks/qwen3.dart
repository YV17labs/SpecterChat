/// Hooks for Qwen 3.5 models.
///
/// Qwen 3.5 frequently hallucinates tool calls as raw XML
/// (`<tool_call>`, `<function=…>`) in content or thinking output
/// instead of using the native tool-call mechanism.
library;
import 'llm_hook.dart';

final _patterns = [
  RegExp(r'<tool_call>', caseSensitive: false),
  RegExp(r'<function=\w+', caseSensitive: false),
  RegExp(r'<invoke\s', caseSensitive: false),
];

class Qwen35Hook extends LlmHook {
  @override
  final modelPattern = RegExp(r'qwen3\.5', caseSensitive: false);

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
}

/// Singleton instance registered in the hook registry.
final qwen35Hook = Qwen35Hook();
