import '../models/app_settings.dart';

/// Where [AppSettings] are persisted between launches.
abstract interface class ISettingsStore {
  /// `null` when nothing has been saved yet or the stored payload is
  /// unreadable — the caller falls back to defaults either way.
  Future<AppSettings?> load();

  Future<void> save(AppSettings settings);
}
