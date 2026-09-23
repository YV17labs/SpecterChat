import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/chat/context_budget.dart';
import '../../domain/models/request_profile.dart';
import '../../domain/services/i_llm_service.dart';
import '../../infrastructure/llm/llm_service.dart';
import 'effective_settings_provider.dart';
import 'model_catalog_provider.dart';
import 'settings_provider.dart';

/// The HTTP client for the configured server. Rebuilt only when the
/// connection settings change — sampling and image options travel with
/// each request as a [RequestProfile] (see [requestProfileProvider]).
final llmServiceProvider = Provider<ILlmService>((ref) {
  final api = ref.watch(settingsProvider.select((s) => s.api));
  return LlmService.fromSettings(apiSettings: api);
});

/// What the next send carries besides the messages: the effective
/// sampling parameters for a text model, the effective image options for
/// an image model.
final requestProfileProvider = Provider<RequestProfile>((ref) {
  final imageModel = ref.watch(selectedImageModelProvider);
  if (imageModel != null) {
    final image = ref.watch(effectiveSettingsProvider.select((s) => s.image));
    return ImageRequestProfile(image: image);
  }
  final generation = ref.watch(
    effectiveSettingsProvider.select((s) => s.generation),
  );
  return TextRequestProfile(generation: generation);
});

/// What the next send may carry, and so what its history loses first.
///
/// An image request gets no budget: the server reads the images the
/// client re-sends and ignores the window this setting describes, so
/// there is nothing here to weigh.
final contextBudgetProvider = Provider<ContextBudget>((ref) {
  if (ref.watch(selectedImageModelProvider) != null) {
    return const ContextBudget.unlimited();
  }
  final settings = ref.watch(effectiveSettingsProvider);
  return ContextBudget(
    contextLength: settings.contextLength,
    answerTokens: settings.generation.maxTokens,
    imageLimit: settings.imageHistoryLimit,
  );
});
