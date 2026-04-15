import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

final _log = Logger('SettingsProvider');

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _key = 'app_settings';
  Timer? _saveTimer;

  @override
  AppSettings build() {
    ref.onDispose(() => _saveTimer?.cancel());
    _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json != null) {
      try {
        final raw = jsonDecode(json) as Map<String, dynamic>;
        _migrateAuthTokenToHeaders(raw);
        var loaded = AppSettings.fromJson(raw);
        // Reset runtime-only MCP state — actual connections don't
        // survive an app restart.
        loaded = loaded.copyWith(
          mcpServers: loaded.mcpServers
              .map((s) => s.copyWith(
                    connected: false,
                    tools: [],
                    instructions: '',
                  ))
              .toList(),
        );
        state = loaded;
      } catch (e, st) {
        _log.warning('Corrupted settings JSON, using defaults', e, st);
      }
    }
  }

  /// One-shot migration: the old schema stored a Bearer token in `authToken`.
  /// Fold it into `headers["Authorization"]` so the new headers-based config
  /// keeps working for users upgrading from the previous version.
  void _migrateAuthTokenToHeaders(Map<String, dynamic> raw) {
    final servers = raw['mcpServers'];
    if (servers is! List) return;
    for (final s in servers) {
      if (s is! Map) continue;
      final token = s['authToken'];
      if (token is String && token.isNotEmpty) {
        final existing = s['headers'];
        final headers = existing is Map
            ? Map<String, dynamic>.from(existing)
            : <String, dynamic>{};
        headers.putIfAbsent('Authorization', () => 'Bearer $token');
        s['headers'] = headers;
      }
      s.remove('authToken');
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(state.toJson()));
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

  void updateDefaultSystemPrompt(String prompt) {
    state = state.copyWith(defaultSystemPrompt: prompt);
    _scheduleSave();
  }

  void addMcpServer(McpServerConfig server) {
    state = state.copyWith(
      mcpServers: [...state.mcpServers, server],
    );
    _scheduleSave();
  }

  void removeMcpServer(String serverId) {
    state = state.copyWith(
      mcpServers: state.mcpServers.where((s) => s.id != serverId).toList(),
    );
    _scheduleSave();
  }

  void updateMcpServer(McpServerConfig server) {
    state = state.copyWith(
      mcpServers: state.mcpServers
          .map((s) => s.id == server.id ? server : s)
          .toList(),
    );
    _scheduleSave();
  }

  void replaceMcpServers(List<McpServerConfig> servers) {
    state = state.copyWith(mcpServers: servers);
    _scheduleSave();
  }
}
