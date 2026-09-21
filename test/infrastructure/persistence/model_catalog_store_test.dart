import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/infrastructure/persistence/shared_preferences_model_catalog_store.dart';

void main() {
  const store = SharedPreferencesModelCatalogStore();
  const info = ImageModelInfo(
    backend: 'torch',
    device: 'mps',
    capabilities: ImageCapabilities(referenceEdit: true, rgba: true),
    defaults: ImageDefaults(steps: 30),
  );

  test('empty when nothing was saved', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await store.load(), isEmpty);
  });

  test('round-trips the map under its own key', () async {
    SharedPreferences.setMockInitialValues({});
    await store.save(const {'qwen-image-2.1': info});
    expect(await store.load(), {'qwen-image-2.1': info});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'model_catalog.image_models'});
    expect(prefs.containsKey('app_settings'), isFalse);
  });

  test('corrupted or mis-shaped JSON is ignored', () async {
    SharedPreferences.setMockInitialValues({
      'model_catalog.image_models': '{not json',
    });
    expect(await store.load(), isEmpty);
    SharedPreferences.setMockInitialValues({
      'model_catalog.image_models': '{"x": 42}',
    });
    expect(await store.load(), isEmpty);
  });
}
