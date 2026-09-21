import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/model_info.dart';
import '../../domain/repositories/i_model_catalog_store.dart';

final _log = Logger('ModelCatalogStore');

/// [IModelCatalogStore] on top of `shared_preferences`, as one JSON object
/// keyed by model id — deliberately a separate key from the settings blob,
/// so a cache of server data never rides along with user preferences.
class SharedPreferencesModelCatalogStore implements IModelCatalogStore {
  static const _key = 'model_catalog.image_models';

  const SharedPreferencesModelCatalogStore();

  @override
  Future<Map<String, ImageModelInfo>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json == null) return const {};
    try {
      final raw = jsonDecode(json) as Map<String, dynamic>;
      return {
        for (final e in raw.entries)
          e.key: ImageModelInfo.fromJson(e.value as Map<String, dynamic>),
      };
    } on FormatException catch (e, st) {
      _log.warning('Corrupted model catalog JSON, ignoring', e, st);
    } on TypeError catch (e, st) {
      _log.warning('Unexpected model catalog JSON shape, ignoring', e, st);
    }
    return const {};
  }

  @override
  Future<void> save(Map<String, ImageModelInfo> imageModels) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        for (final e in imageModels.entries) e.key: e.value.toJson(),
      }),
    );
  }
}
