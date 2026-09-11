import '../../domain/models/app_settings.dart';
import '../../domain/models/mcp_server_state.dart';

/// A server that is enabled globally, enabled for the current conversation
/// and currently connected — the only servers whose tools reach the model.
///
/// Every consumer (tool list sent to the LLM, tool execution, prompts,
/// resources, merged instructions) works from the same list, so a tool the
/// model was offered is always a tool the executor can route.
class ActiveMcpServer {
  final McpServerConfig config;
  final McpServerState state;

  const ActiveMcpServer({required this.config, required this.state});

  String get id => config.id;
  String get name => config.name;
}

/// Find which server owns [toolName], or `null` if none does. Tools the
/// user switched off are not offered to the model and are not routable.
String? findServerForTool(List<ActiveMcpServer> servers, String toolName) {
  for (final server in servers) {
    for (final tool in server.state.enabledTools) {
      if (tool.name == toolName) return server.id;
    }
  }
  return null;
}

/// Tools the model may call, across every active server.
List<McpToolInfo> enabledToolsOf(List<ActiveMcpServer> servers) => [
  for (final s in servers) ...s.state.enabledTools,
];

/// Server instructions merged into one system-prompt section.
String mergedInstructionsOf(List<ActiveMcpServer> servers) => [
  for (final s in servers)
    if (s.state.instructions.isNotEmpty)
      '## MCP Server: ${s.name}\n${s.state.instructions}',
].join('\n\n');
