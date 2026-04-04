import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../services/i_mcp_service.dart';
import '../services/mcp_service.dart';
import 'settings_provider.dart';

final mcpServiceProvider = Provider<IMcpService>((ref) {
  final service = McpService();
  ref.onDispose(() => service.disconnectAll());
  return service;
});

/// All enabled MCP tools in OpenAI format.
final mcpToolsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final servers = ref.watch(settingsProvider.select((s) => s.mcpServers));
  final allTools = <McpToolInfo>[];

  for (final server in servers) {
    if (server.enabled && server.connected) {
      allTools.addAll(server.tools);
    }
  }

  return McpService.toolsToOpenAiFormat(allTools);
});

/// Aggregated MCP server instructions for inclusion in the system prompt.
final mcpInstructionsProvider = Provider<String>((ref) {
  final servers = ref.watch(settingsProvider.select((s) => s.mcpServers));
  final parts = <String>[];

  for (final server in servers) {
    if (server.enabled && server.connected && server.instructions.isNotEmpty) {
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
