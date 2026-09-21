import '../models/model_info.dart';

/// Where the last known description of the server's image models is kept
/// between launches, keyed by model id.
///
/// This is a cache of what the server reported, not a user setting — which
/// is why it is not part of `AppSettings`. It exists so the settings panel
/// knows the selected model is an image generator before the first
/// `/models` round-trip completes.
abstract interface class IModelCatalogStore {
  /// Empty when nothing has been saved yet or the payload is unreadable.
  Future<Map<String, ImageModelInfo>> load();

  Future<void> save(Map<String, ImageModelInfo> imageModels);
}
