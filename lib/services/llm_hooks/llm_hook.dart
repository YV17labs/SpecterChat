/// Contract for model-specific hooks.
///
/// Each implementation targets a model family/version and provides
/// behavioral overrides. The service never knows which models exist —
/// it only works through this interface.
abstract class LlmHook {
  /// Regex tested against the selected model name (e.g. `qwen3\.5`).
  RegExp get modelPattern;

  /// Returns `true` if [text] contains hallucinated output that the
  /// model produced instead of using the native tool-call mechanism.
  bool detectHallucination(String text);

  /// Correction prompt sent back to the model after a hallucination.
  String get hallucinationCorrection;
}
