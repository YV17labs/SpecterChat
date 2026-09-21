import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/domain/models/request_profile.dart';
import 'package:specterchat/presentation/providers/llm_provider.dart';
import 'package:specterchat/presentation/providers/model_catalog_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';

import '../../support/async.dart';
import '../../support/fakes.dart';

void main() {
  late ProviderContainer container;
  late InMemoryModelCatalogStore catalog;
  late FakeLlmService llm;

  setUp(() {
    catalog = InMemoryModelCatalogStore();
    llm = FakeLlmService([]);
    container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        modelCatalogStoreProvider.overrideWithValue(catalog),
        llmServiceProvider.overrideWith((_) => llm),
      ],
    );
    addTearDown(container.dispose);
  });

  test('a text model yields the effective sampling parameters', () async {
    container
        .read(settingsProvider.notifier)
        .updateGeneration(const GenerationSettings(temperature: 0.2));
    final profile = container.read(requestProfileProvider);
    expect(profile, isA<TextRequestProfile>());
    expect((profile as TextRequestProfile).generation.temperature, 0.2);
  });

  test('an image model yields the effective image options', () async {
    catalog.stored = const {'img': ImageModelInfo()};
    container.read(modelCatalogProvider);
    await settle();
    await settle();
    container
        .read(settingsProvider.notifier)
        .updateApi(const ApiSettings(selectedModel: 'img'));
    container
        .read(settingsProvider.notifier)
        .updateImage(const ImageSettings(steps: 4));
    final profile = container.read(requestProfileProvider);
    expect(profile, isA<ImageRequestProfile>());
    expect((profile as ImageRequestProfile).image.steps, 4);
  });
}
