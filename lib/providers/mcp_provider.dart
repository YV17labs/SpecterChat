import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../services/mcp_service.dart';
import 'settings_provider.dart';

final mcpServiceProvider = Provider<McpService>((ref) {
  final service = McpService();
  ref.onDispose(() => service.disconnectAll());
  return service;
});

/// Maps server ID -> tool owner server ID for routing tool calls.
final toolToServerMapProvider =
    StateProvider<Map<String, String>>((ref) => {});

/// All enabled MCP tools in OpenAI format.
final mcpToolsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final settings = ref.watch(settingsProvider);
  final allTools = <McpToolInfo>[];

  for (final server in settings.mcpServers) {
    if (server.enabled && server.connected) {
      allTools.addAll(server.tools);
    }
  }

  return McpService.toolsToOpenAiFormat(allTools);
});

/// Find which server owns a given tool name.
String? findServerForTool(List<McpServerConfig> servers, String toolName) {
  for (final server in servers) {
    if (server.enabled && server.connected) {
      for (final tool in server.tools) {
        if (tool.name == toolName) {
          return server.id;
        }
      }
    }
  }
  return null;
}
