import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/image_settings.dart';
import '../../domain/repositories/i_settings_store.dart';
import '../../infrastructure/persistence/shared_preferences_settings_store.dart';

/// Override in tests with an in-memory store.
final settingsStoreProvider = Provider<ISettingsStore>(
  (_) => const SharedPreferencesSettingsStore(),
);

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// Global settings. Starts with defaults, replaces them once the store has
/// loaded, and writes back on a short debounce after every change.
class SettingsNotifier extends Notifier<AppSettings> {
  static const _saveDebounce = Duration(milliseconds: 500);
  Timer? _saveTimer;

  @override
  AppSettings build() {
    ref.onDispose(() => _saveTimer?.cancel());
    unawaited(_load());
    return const AppSettings();
  }

  Future<void> _load() async {
    final loaded = await ref.read(settingsStoreProvider).load();
    if (loaded != null) state = loaded;
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () {
      unawaited(ref.read(settingsStoreProvider).save(state));
    });
  }

  void updateApi(ApiSettings api) {
    state = state.copyWith(api: api);
    _scheduleSave();
  }

  void updateGeneration(GenerationSettings generation) {
    state = state.copyWith(generation: generation);
    _scheduleSave();
  }

  void updateImage(ImageSettings image) {
    state = state.copyWith(image: image);
    _scheduleSave();
  }

  void updatePhotoMetadata(PhotoMetadataExport photoMetadata) {
    state = state.copyWith(photoMetadata: photoMetadata);
    _scheduleSave();
  }

  void updateDefaultSystemPrompt(String prompt) {
    state = state.copyWith(defaultSystemPrompt: prompt);
    _scheduleSave();
  }

  void removeMcpServer(String serverId) {
    state = state.copyWith(
      mcpServers: state.mcpServers.where((s) => s.id != serverId).toList(),
    );
    _scheduleSave();
  }

  void replaceMcpServers(List<McpServerConfig> servers) {
    state = state.copyWith(mcpServers: servers);
    _scheduleSave();
  }
}
