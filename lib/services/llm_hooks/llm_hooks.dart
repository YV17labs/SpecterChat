/// LLM hook system.
///
/// Hooks allow model-specific behaviors to be injected without the
/// core chat logic knowing which models exist. Each hook implements
/// [LlmHook] and declares a [modelPattern] that determines when it
/// activates. The service matches the selected model name and
/// delegates to the first matching hook.
///
/// To add hooks for a new model:
/// 1. Create a file in this directory (e.g. `deepseek.dart`).
/// 2. Implement [LlmHook] and register it in [_hooks].
library;

export 'llm_hook.dart';

import 'llm_hook.dart';
import 'qwen3.dart';

// ---------------------------------------------------------------------------
// Hook registry — add new hooks here
// ---------------------------------------------------------------------------

final _hooks = <LlmHook>[
  qwen3Hook,
].._verifyPrefix();

extension on List<LlmHook> {
  void _verifyPrefix() {
    for (final hook in this) {
      assert(
        hook.hallucinationCorrection.startsWith(correctionPrefix),
        '${hook.runtimeType}.hallucinationCorrection must start with '
        'correctionPrefix ("$correctionPrefix")',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Maximum number of automatic retries for hallucination recovery.
const maxHallucinationRetries = 2;

/// Prefix shared by all correction prompts — used to identify
/// auto-correction messages in the UI without knowing the model.
const correctionPrefix = 'That last attempt did not produce a valid tool call';

/// Returns the first hook matching [model], or `null`.
LlmHook? hookFor(String model) {
  for (final hook in _hooks) {
    if (hook.modelPattern.hasMatch(model)) return hook;
  }
  return null;
}

/// Correction prompt to send after a hallucination is detected.
String hallucinationCorrection(String model) {
  return hookFor(model)?.hallucinationCorrection ?? '';
}
