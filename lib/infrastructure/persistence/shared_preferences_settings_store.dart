import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/repositories/i_settings_store.dart';

final _log = Logger('SettingsStore');

/// [ISettingsStore] on top of `shared_preferences`, as one JSON blob.
///
/// Owns the on-disk schema: any migration of stored JSON from an older
/// version happens here, before the payload reaches [AppSettings.fromJson].
class SharedPreferencesSettingsStore implements ISettingsStore {
  static const _key = 'app_settings';

  const SharedPreferencesSettingsStore();

  @override
  Future<AppSettings?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json == null) return null;
    try {
      final raw = jsonDecode(json) as Map<String, dynamic>;
      migrateAuthTokenToHeaders(raw);
      return AppSettings.fromJson(raw);
    } on FormatException catch (e, st) {
      _log.warning('Corrupted settings JSON, using defaults', e, st);
    } on TypeError catch (e, st) {
      _log.warning('Unexpected settings JSON shape, using defaults', e, st);
    }
    return null;
  }

  @override
  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }

  /// One-shot migration: the old schema stored a Bearer token in
  /// `authToken`. Fold it into `headers["Authorization"]` so the
  /// headers-based config keeps working for users upgrading.
  ///
  /// Runtime fields older versions also persisted (`connected`, `tools`…)
  /// are simply ignored by `McpServerConfig.fromJson`.
  static void migrateAuthTokenToHeaders(Map<String, dynamic> raw) {
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
}
