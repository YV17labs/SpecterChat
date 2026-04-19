import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

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

/// Servers enabled for the active conversation AND currently connected.
///
/// All per-conversation aggregators (tools, instructions, prompts, resources)
/// filter through this single predicate so the "active server" semantics stay
/// consistent.
final activeMcpServersProvider = Provider<List<McpServerConfig>>((ref) {
  final servers = ref.watch(settingsProvider.select((s) => s.mcpServers));
  final enabledIds = ref.watch(
      effectiveSettingsProvider.select((s) => s.enabledMcpServerIds));
  return [
    for (final s in servers)
      if (enabledIds.contains(s.id) && s.connected) s,
  ];
});

/// MCP tools in OpenAI format, filtered by per-conversation enabled servers.
final mcpToolsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final servers = ref.watch(activeMcpServersProvider);
  return McpService.toolsToOpenAiFormat([
    for (final s in servers) ...s.tools,
  ]);
});

/// Aggregated MCP server instructions, filtered by per-conversation enabled servers.
final mcpInstructionsProvider = Provider<String>((ref) {
  final servers = ref.watch(activeMcpServersProvider);
  return [
    for (final s in servers)
      if (s.instructions.isNotEmpty)
        '## MCP Server: ${s.name}\n${s.instructions}',
  ].join('\n\n');
});

/// One prompt offered by a specific MCP server.
class McpPromptRef {
  final String serverId;
  final String serverName;
  final McpPrompt prompt;

  const McpPromptRef({
    required this.serverId,
    required this.serverName,
    required this.prompt,
  });
}

/// One resource offered by a specific MCP server.
class McpResourceRef {
  final String serverId;
  final String serverName;
  final McpResource resource;

  const McpResourceRef({
    required this.serverId,
    required this.serverName,
    required this.resource,
  });
}

/// Pending text to inject into the chat input box.
///
/// The MCP server tile sets this when the user picks a prompt or a resource;
/// the chat input widget listens, appends the text to its controller, then
/// resets the provider to `null`. This one-shot channel avoids coupling the
/// sidebar widget to the chat input's controller.
final chatInputInjectionProvider = StateProvider<String?>((ref) => null);

/// Prompts offered by enabled + connected servers for the active conversation.
final mcpPromptsProvider = Provider<List<McpPromptRef>>((ref) {
  final servers = ref.watch(activeMcpServersProvider);
  return [
    for (final s in servers)
      for (final p in s.prompts)
        McpPromptRef(serverId: s.id, serverName: s.name, prompt: p),
  ];
});

/// Resources offered by enabled + connected servers for the active conversation.
final mcpResourcesProvider = Provider<List<McpResourceRef>>((ref) {
  final servers = ref.watch(activeMcpServersProvider);
  return [
    for (final s in servers)
      for (final r in s.resources)
        McpResourceRef(serverId: s.id, serverName: s.name, resource: r),
  ];
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
    prompts: result.prompts,
    resources: result.resources,
    resourceTemplates: result.resourceTemplates,
    icons: result.icons,
    instructions: result.instructions,
  ));
}
