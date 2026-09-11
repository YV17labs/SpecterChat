import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../application/mcp/active_mcp_server.dart';
import '../../domain/models/app_settings.dart';
import '../../domain/models/mcp_server_state.dart';
import '../../domain/services/i_mcp_service.dart';
import '../../infrastructure/mcp/mcp_service.dart';
import 'effective_settings_provider.dart';
import 'settings_provider.dart';

final _log = Logger('McpProvider');

final mcpServiceProvider = Provider<IMcpService>((ref) {
  final service = McpService();
  ref.onDispose(service.disconnectAll);
  return service;
});

/// Runtime state of every configured server, keyed by server id. Absent
/// key == disconnected. Never persisted.
final mcpServerStatesProvider =
    NotifierProvider<McpConnectionController, Map<String, McpServerState>>(
      McpConnectionController.new,
    );

/// State for one server; `McpServerState()` (disconnected) when unknown.
final mcpServerStateProvider = Provider.family<McpServerState, String>((
  ref,
  id,
) {
  return ref.watch(mcpServerStatesProvider.select((states) => states[id])) ??
      const McpServerState();
});

/// Owns MCP connections: connect/disconnect against the service and keep
/// the observable per-server state in step with it.
class McpConnectionController extends Notifier<Map<String, McpServerState>> {
  @override
  Map<String, McpServerState> build() => const {};

  IMcpService get _service => ref.read(mcpServiceProvider);

  /// Connect [config]. Throws on failure after recording the error in the
  /// server's state, so the caller can both react and show it.
  Future<void> connect(McpServerConfig config) async {
    _set(
      config.id,
      const McpServerState(status: McpConnectionStatus.connecting),
    );
    try {
      final result = await _service.connect(config);
      _set(
        config.id,
        McpServerState(
          status: McpConnectionStatus.connected,
          tools: result.tools,
          prompts: result.prompts,
          resources: result.resources,
          resourceTemplates: result.resourceTemplates,
          icons: result.icons,
          instructions: result.instructions,
        ),
      );
    } catch (e, st) {
      _log.warning('Failed to connect to MCP server: ${config.name}', e, st);
      _set(config.id, McpServerState(lastError: '$e'));
      rethrow;
    }
  }

  void disconnect(String serverId) {
    _service.disconnect(serverId);
    state = {...state}..remove(serverId);
  }

  /// Drop connections for servers that are no longer configured (the JSON
  /// editor removed them or rotated their ids).
  void disconnectMissing(Iterable<String> configuredIds) {
    final keep = configuredIds.toSet();
    for (final id in state.keys.where((id) => !keep.contains(id)).toList()) {
      disconnect(id);
    }
  }

  void setToolEnabled({
    required String serverId,
    required String toolName,
    required bool enabled,
  }) {
    final current = state[serverId];
    if (current == null) return;
    _set(
      serverId,
      current.copyWith(
        tools: [
          for (final t in current.tools)
            t.name == toolName ? t.copyWith(enabled: enabled) : t,
        ],
      ),
    );
  }

  void _set(String id, McpServerState value) {
    state = {...state, id: value};
  }
}

/// Servers enabled globally, enabled for the active conversation AND
/// currently connected. Every per-conversation aggregator (tools,
/// instructions, prompts, resources) and the tool executor read this one
/// list, so "active server" means the same thing everywhere.
final activeMcpServersProvider = Provider<List<ActiveMcpServer>>((ref) {
  final configs = ref.watch(settingsProvider.select((s) => s.mcpServers));
  final states = ref.watch(mcpServerStatesProvider);
  final enabledIds = ref.watch(
    effectiveSettingsProvider.select((s) => s.enabledMcpServerIds),
  );
  return [
    for (final config in configs)
      if (config.enabled && enabledIds.contains(config.id))
        if (states[config.id] case final state? when state.connected)
          ActiveMcpServer(config: config, state: state),
  ];
});
