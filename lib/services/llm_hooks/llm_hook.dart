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

  /// Per-chunk inactivity budget. If the server goes silent for this
  /// long mid-stream, the client gives up waiting and yields a
  /// `StreamStalled` event. `null` = wait forever (the stock behavior).
  Duration? get streamInactivityTimeout => null;

  /// Correction prompt injected as a user message to nudge the model
  /// forward after a stalled stream. `null` = finalize silently without
  /// relaunching the pipeline.
  String? get streamStallCorrection => null;
}
