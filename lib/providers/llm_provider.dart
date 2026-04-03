import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../services/llm_service.dart';
import 'settings_provider.dart';

final llmServiceProvider = Provider<LlmService>((ref) {
  final settings = ref.watch(settingsProvider);
  return LlmService(
    apiSettings: settings.api,
    generationSettings: settings.generation,
  );
});

final availableModelsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final llm = ref.watch(llmServiceProvider);
  return llm.fetchModels();
});
