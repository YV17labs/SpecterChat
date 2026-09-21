import 'package:flutter_riverpod/flutter_riverpod.dart';

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
