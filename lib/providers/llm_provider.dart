import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/i_llm_service.dart';
import '../services/llm_service.dart';
import 'settings_provider.dart';

final llmServiceProvider = Provider<ILlmService>((ref) {
  final api = ref.watch(settingsProvider.select((s) => s.api));
  final generation = ref.watch(settingsProvider.select((s) => s.generation));
  return LlmService.fromSettings(
    apiSettings: api,
    generationSettings: generation,
  );
});

final availableModelsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final llm = ref.watch(llmServiceProvider);
  return llm.fetchModels();
});
