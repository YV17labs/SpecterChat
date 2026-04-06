import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../services/i_mcp_service.dart';
import '../services/mcp_service.dart';
import 'effective_settings_provider.dart';
import 'settings_provider.dart';

final mcpServiceProvider = Provider<IMcpService>((ref) {
  final service = McpService();
  ref.onDispose(() => service.disconnectAll());
  return service;
});

/// MCP tools in OpenAI format, filtered by per-conversation enabled servers.
final mcpToolsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final servers = ref.watch(settingsProvider.select((s) => s.mcpServers));
  final enabledIds = ref.watch(
      effectiveSettingsProvider.select((s) => s.enabledMcpServerIds));
  final allTools = <McpToolInfo>[];

  for (final server in servers) {
    if (enabledIds.contains(server.id) && server.connected) {
      allTools.addAll(server.tools);
    }
  }

  return McpService.toolsToOpenAiFormat(allTools);
});

/// Aggregated MCP server instructions, filtered by per-conversation enabled servers.
final mcpInstructionsProvider = Provider<String>((ref) {
  final servers = ref.watch(settingsProvider.select((s) => s.mcpServers));
  final enabledIds = ref.watch(
      effectiveSettingsProvider.select((s) => s.enabledMcpServerIds));
  final parts = <String>[];

  for (final server in servers) {
    if (enabledIds.contains(server.id) &&
        server.connected &&
        server.instructions.isNotEmpty) {
      parts.add('## MCP Server: ${server.name}\n${server.instructions}');
    }
  }

  return parts.join('\n\n');
});

/// Connect a server and update its state in settings.
Future<void> connectMcpServer({
  required McpServerConfig server,
  required IMcpService mcpService,
  required SettingsNotifier notifier,
}) async {
  final result = await mcpService.connect(server);
  notifier.updateMcpServer(server.copyWith(
    connected: true,
    tools: result.tools,
    instructions: result.instructions,
  ));
}
