import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/model_info.dart';
import '../../domain/repositories/i_model_catalog_store.dart';
import '../../infrastructure/persistence/shared_preferences_model_catalog_store.dart';
import 'llm_provider.dart';
import 'settings_provider.dart';

/// Override in tests with an in-memory store.
final modelCatalogStoreProvider = Provider<IModelCatalogStore>(
  (_) => const SharedPreferencesModelCatalogStore(),
);

/// What the server lists under `/models`, plus the last known description
/// of the image models among them.
class ModelCatalog {
  /// The live list: loading until the first fetch settles, then the
  /// result of the latest [ModelCatalogNotifier.refresh].
  final AsyncValue<List<ModelInfo>> models;

  /// Description of every image model the server ever listed, by id.
  /// Persisted, so it is right at launch before the first fetch completes
  /// and survives a server that is temporarily down.
  final Map<String, ImageModelInfo> imageModels;

  const ModelCatalog({required this.models, required this.imageModels});

  ModelCatalog copyWith({
    AsyncValue<List<ModelInfo>>? models,
    Map<String, ImageModelInfo>? imageModels,
  }) => ModelCatalog(
    models: models ?? this.models,
    imageModels: imageModels ?? this.imageModels,
  );
}

final modelCatalogProvider =
    NotifierProvider<ModelCatalogNotifier, ModelCatalog>(
      ModelCatalogNotifier.new,
    );

/// Owns the `/models` fetch and the persisted image-model cache.
///
/// Fetching is an action ([refresh]), not a derivation: it runs once at
/// startup, again whenever the connection changes, and when the user asks.
/// Keeping it here rather than in a `FutureProvider` means the cache write
/// is an ordinary effect of an action instead of a side effect hidden in
/// a provider's `build`.
class ModelCatalogNotifier extends Notifier<ModelCatalog> {
  /// The connection fields are edited keystroke by keystroke; wait for the
  /// user to pause before hitting a half-typed host.
  static const connectionDebounce = Duration(milliseconds: 400);

  late final Future<void> _loaded;
  int _fetchSequence = 0;
  Timer? _connectionTimer;

  @override
  ModelCatalog build() {
    // A new base URL or key is a new server: its model list replaces ours.
    // Selecting a model or editing the context length is not.
    ref.listen(settingsProvider.select((s) => (s.api.baseUrl, s.api.apiKey)), (
      _,
      _,
    ) {
      _connectionTimer?.cancel();
      _connectionTimer = Timer(connectionDebounce, () => unawaited(refresh()));
    });
    ref.onDispose(() => _connectionTimer?.cancel());
    _loaded = _load();
    unawaited(_loaded.then((_) => refresh()));
    return const ModelCatalog(models: AsyncLoading(), imageModels: {});
  }

  Future<void> _load() async {
    final stored = await ref.read(modelCatalogStoreProvider).load();
    if (!ref.mounted) return;
    state = state.copyWith(imageModels: stored);
  }

  /// Fetch the model list again. Concurrent calls are fine: only the
  /// latest one's result is applied.
  Future<void> refresh() async {
    final sequence = ++_fetchSequence;
    bool stale() => !ref.mounted || sequence != _fetchSequence;
    await _loaded;
    if (stale()) return;
    state = state.copyWith(models: const AsyncLoading());
    final List<ModelInfo> models;
    try {
      models = await ref.read(llmServiceProvider).fetchModels();
    } catch (e, st) {
      if (stale()) return;
      state = state.copyWith(models: AsyncError(e, st));
      return;
    }
    if (stale()) return;
    final merged = _mergeImageModels(state.imageModels, models);
    final changed = !mapEquals(merged, state.imageModels);
    state = ModelCatalog(models: AsyncData(models), imageModels: merged);
    if (changed) await ref.read(modelCatalogStoreProvider).save(merged);
  }

  /// Ids the server now lists as image models are added or replaced; ids
  /// it lists as text models are forgotten; ids absent from the list are
  /// left as they were (the server may be a different one for a moment).
  static Map<String, ImageModelInfo> _mergeImageModels(
    Map<String, ImageModelInfo> known,
    List<ModelInfo> models,
  ) {
    final merged = Map<String, ImageModelInfo>.from(known);
    for (final m in models) {
      final image = m.image;
      if (image == null) {
        merged.remove(m.id);
      } else {
        merged[m.id] = image;
      }
    }
    return merged;
  }
}

/// Description of the selected model when it is an image generator,
/// `null` for a text LLM or an unknown model.
final selectedImageModelProvider = Provider<ImageModelInfo?>((ref) {
  final selected = ref.watch(
    settingsProvider.select((s) => s.api.selectedModel),
  );
  final known = ref.watch(modelCatalogProvider.select((c) => c.imageModels));
  return known[selected];
});
