/// Prefix shared by every correction prompt — lets the UI recognise an
/// auto-injected correction message without knowing which model produced
/// the hallucination.
const correctionPrefix = 'That last attempt did not produce a valid tool call';

/// Contract for model-specific hooks.
///
/// Each implementation targets a model family/version and provides
/// behavioral overrides. The chat pipeline never knows which models exist —
/// it only works through this interface.
abstract interface class LlmHook {
  /// Regex tested against the selected model name (e.g. `qwen3\.5`).
  RegExp get modelPattern;

  /// Returns `true` if [text] contains hallucinated output that the
  /// model produced instead of using the native tool-call mechanism.
  bool detectHallucination(String text);

  /// Correction prompt sent back to the model after a hallucination.
  /// Must start with [correctionPrefix].
  String get hallucinationCorrection;
}
