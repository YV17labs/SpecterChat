import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/presentation/providers/llm_provider.dart';
import 'package:specterchat/presentation/providers/model_catalog_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';

import '../../support/async.dart';
import '../../support/fakes.dart';

const _image = ImageModelInfo(backend: 'torch');
const _imageModel = ModelInfo(id: 'img', image: _image);
const _textModel = ModelInfo(id: 'txt');

void main() {
  late FakeLlmService llm;
  late InMemoryModelCatalogStore store;
  late InMemorySettingsStore settingsStore;
  late ProviderContainer container;

  setUp(() {
    llm = FakeLlmService([]);
    store = InMemoryModelCatalogStore();
    settingsStore = InMemorySettingsStore();
    container = ProviderContainer(
      overrides: [
        llmServiceProvider.overrideWith((_) => llm),
        modelCatalogStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(settingsStore),
      ],
    );
    addTearDown(container.dispose);
  });

  test('starts loading, fetches once, remembers image models', () async {
    llm.models = const [_imageModel, _textModel];
    final first = container.read(modelCatalogProvider);
    expect(first.models, isA<AsyncLoading<List<ModelInfo>>>());
    expect(first.imageModels, isEmpty);

    await settle();
    await settle();
    final loaded = container.read(modelCatalogProvider);
    expect(loaded.models.value, [_imageModel, _textModel]);
    expect(loaded.imageModels, {'img': _image});
    expect(store.stored, {'img': _image});
    expect(store.saves, 1);
    expect(llm.fetchModelsCalls, 1);
  });

  test('the persisted cache is available before the fetch completes', () async {
    store.stored = const {'img': _image};
    llm.fetchModelsError = LlmException('down');
    container.read(modelCatalogProvider);
    await settle();
    await settle();
    final state = container.read(modelCatalogProvider);
    expect(state.models, isA<AsyncError<List<ModelInfo>>>());
    expect(state.imageModels, {'img': _image});
    expect(store.saves, 0, reason: 'nothing changed, nothing written');
  });

  test('selectedImageModelProvider follows the selection', () async {
    store.stored = const {'img': _image};
    container.read(modelCatalogProvider);
    await settle();
    await settle();
    expect(container.read(selectedImageModelProvider), isNull);
    container
        .read(settingsProvider.notifier)
        .updateApi(const ApiSettings(selectedModel: 'img'));
    expect(container.read(selectedImageModelProvider), _image);
  });

  test('a text model with a cached description is forgotten', () async {
    store.stored = const {'img': _image, 'other': _image};
    llm.models = const [ModelInfo(id: 'img')];
    container.read(modelCatalogProvider);
    await settle();
    await settle();
    expect(container.read(modelCatalogProvider).imageModels, {'other': _image});
    expect(store.stored, {'other': _image});
  });

  test(
    'a connection change refreshes (debounced); a model change does not',
    () async {
      container.read(modelCatalogProvider);
      await settle();
      await settle();
      expect(llm.fetchModelsCalls, 1);

      container
          .read(settingsProvider.notifier)
          .updateApi(const ApiSettings(selectedModel: 'img'));
      await settle();
      await settle();
      expect(llm.fetchModelsCalls, 1);

      // Typed keystroke by keystroke: one fetch once the user pauses.
      for (final url in ['http://o', 'http://ot', 'http://other/v1']) {
        container
            .read(settingsProvider.notifier)
            .updateApi(ApiSettings(baseUrl: url));
      }
      await settle();
      expect(llm.fetchModelsCalls, 1);
      await Future<void>.delayed(
        ModelCatalogNotifier.connectionDebounce +
            const Duration(milliseconds: 50),
      );
      expect(llm.fetchModelsCalls, 2);
    },
  );

  test('refresh() re-fetches and the latest result wins', () async {
    container.read(modelCatalogProvider);
    await settle();
    await settle();
    llm.models = const [_imageModel];
    await container.read(modelCatalogProvider.notifier).refresh();
    expect(container.read(modelCatalogProvider).models.value, [_imageModel]);
    expect(llm.fetchModelsCalls, 2);
  });
}
