import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/i_llm_service.dart';
import '../../infrastructure/llm/llm_service.dart';
import 'effective_settings_provider.dart';
import 'settings_provider.dart';

final llmServiceProvider = Provider<ILlmService>((ref) {
  final api = ref.watch(settingsProvider.select((s) => s.api));
  final generation = ref.watch(
    effectiveSettingsProvider.select((s) => s.generation),
  );
  return LlmService.fromSettings(
    apiSettings: api,
    generationSettings: generation,
  );
});

final availableModelsProvider = FutureProvider.autoDispose<List<String>>((ref) {
  return ref.watch(llmServiceProvider).fetchModels();
});
