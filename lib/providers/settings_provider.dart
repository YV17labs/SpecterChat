import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  static const _key = 'app_settings';

  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json != null) {
      try {
        state = AppSettings.fromJson(jsonDecode(json));
      } catch (_) {
        // Corrupted settings, use defaults
      }
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state.toJson()));
  }

  void updateApi(ApiSettings api) {
    state = state.copyWith(api: api);
    _save();
  }

  void updateGeneration(GenerationSettings generation) {
    state = state.copyWith(generation: generation);
    _save();
  }

  void updateDefaultSystemPrompt(String prompt) {
    state = state.copyWith(defaultSystemPrompt: prompt);
    _save();
  }

  void addMcpServer(McpServerConfig server) {
    state = state.copyWith(
      mcpServers: [...state.mcpServers, server],
    );
    _save();
  }

  void removeMcpServer(String serverId) {
    state = state.copyWith(
      mcpServers: state.mcpServers.where((s) => s.id != serverId).toList(),
    );
    _save();
  }

  void updateMcpServer(McpServerConfig server) {
    state = state.copyWith(
      mcpServers: state.mcpServers
          .map((s) => s.id == server.id ? server : s)
          .toList(),
    );
    _save();
  }
}
