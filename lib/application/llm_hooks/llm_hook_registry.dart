/// LLM hook registry.
///
/// Hooks let model-specific behaviours be injected without the chat
/// pipeline knowing which models exist. Each hook implements [LlmHook] and
/// declares a `modelPattern` that decides when it activates; the registry
/// matches the selected model name and hands back the first hit.
///
/// To add a hook for a new model: create a file in this directory,
/// implement [LlmHook], and add an instance to [defaultLlmHookRegistry].
library;

import '../../domain/services/llm_hook.dart';
import 'qwen3.dart';

class LlmHookRegistry {
  final List<LlmHook> hooks;

  /// Maximum number of automatic retries for hallucination recovery.
  final int maxHallucinationRetries;

  const LlmHookRegistry(this.hooks, {this.maxHallucinationRetries = 2});

  /// Registry with no hooks — every model is treated as well-behaved.
  const LlmHookRegistry.none() : this(const []);

  /// Returns the first hook matching [model], or `null`.
  LlmHook? hookFor(String model) {
    for (final hook in hooks) {
      if (hook.modelPattern.hasMatch(model)) return hook;
    }
    return null;
  }

  /// Every correction prompt must carry [correctionPrefix] — the UI relies
  /// on it to style auto-corrections. Cheap enough to run eagerly.
  void verify() {
    for (final hook in hooks) {
      if (!hook.hallucinationCorrection.startsWith(correctionPrefix)) {
        throw StateError(
          '${hook.runtimeType}.hallucinationCorrection must start with '
          'correctionPrefix ("$correctionPrefix")',
        );
      }
    }
  }
}

/// Hooks shipped with the app.
final defaultLlmHookRegistry = const LlmHookRegistry([Qwen3Hook()])..verify();
