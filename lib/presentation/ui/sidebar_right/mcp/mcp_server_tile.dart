import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../domain/models/app_settings.dart';
import '../../../../domain/models/mcp_server_state.dart';
import '../../../providers/mcp_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../widgets/settings_fields.dart';
import '../../widgets/snack.dart';
import 'mcp_prompt_row.dart';
import 'mcp_resource_row.dart';
import 'mcp_section_widgets.dart';
import 'mcp_server_icon.dart';
import 'mcp_tool_row.dart';

const _sectionPadding = EdgeInsets.fromLTRB(16, 8, 16, 4);

/// One configured MCP server: connection toggle, per-conversation switch,
/// and the tools / prompts / resources it exposes once connected.
class McpServerTile extends ConsumerWidget {
  final McpServerConfig server;

  /// Whether this server is enabled for the current conversation.
  /// `null` means no conversation is selected (global mode).
  final bool? enabledInConversation;

  /// Called when the user toggles the per-conversation enable switch.
  final ValueChanged<bool>? onToggleConversation;

  const McpServerTile({
    super.key,
    required this.server,
    this.enabledInConversation,
    this.onToggleConversation,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mcpServerStateProvider(server.id));
    final isConversationMode = enabledInConversation != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: McpServerIcon(
          icons: state.icons,
          connected: state.connected,
          connecting: state.connecting,
        ),
        title: Text(
          server.name,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          server.url,
          style: context.specterStyles.caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (enabledInConversation case final enabled?)
              Switch(
                value: enabled,
                onChanged: onToggleConversation,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            IconButton(
              icon: Icon(
                state.connected ? Icons.link_off : Icons.link,
                size: 16,
              ),
              tooltip: state.connected ? 'Disconnect' : 'Connect',
              onPressed: state.connecting
                  ? null
                  : () => _toggleConnection(context, ref, state).ignore(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            if (!isConversationMode)
              IconButton(
                icon: const Icon(Icons.delete, size: 16),
                tooltip: 'Remove',
                onPressed: () {
                  ref
                      .read(mcpServerStatesProvider.notifier)
                      .disconnect(server.id);
                  ref
                      .read(settingsProvider.notifier)
                      .removeMcpServer(server.id);
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
          ],
        ),
        children: [
          _ToolsSection(serverId: server.id, state: state),
          _PromptsSection(serverId: server.id, state: state),
          _ResourcesSection(serverId: server.id, state: state),
        ],
      ),
    );
  }

  Future<void> _toggleConnection(
    BuildContext context,
    WidgetRef ref,
    McpServerState state,
  ) async {
    final controller = ref.read(mcpServerStatesProvider.notifier);
    if (state.connected) {
      controller.disconnect(server.id);
      return;
    }
    try {
      await controller.connect(server);
      // Connecting from inside a conversation is a strong signal the user
      // wants the server there too.
      if (enabledInConversation == false) onToggleConversation?.call(true);
    } catch (e) {
      if (!context.mounted) return;
      showSnack(context, 'Failed to connect: $e');
    }
  }
}

class _ToolsSection extends StatelessWidget {
  final String serverId;
  final McpServerState state;

  const _ToolsSection({required this.serverId, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.tools.isEmpty) {
      return state.connected
          ? const McpEmptyHint(text: 'No tools available')
          : const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Tools', padding: _sectionPadding),
        for (final tool in state.tools)
          McpToolRow(serverId: serverId, tool: tool),
      ],
    );
  }
}

class _PromptsSection extends StatelessWidget {
  final String serverId;
  final McpServerState state;

  const _PromptsSection({required this.serverId, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.prompts.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Prompts', padding: _sectionPadding),
        for (final prompt in state.prompts)
          McpPromptRow(serverId: serverId, prompt: prompt),
      ],
    );
  }
}

class _ResourcesSection extends StatelessWidget {
  final String serverId;
  final McpServerState state;

  const _ResourcesSection({required this.serverId, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.resources.isEmpty && state.resourceTemplates.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Resources', padding: _sectionPadding),
        for (final resource in state.resources)
          McpResourceRow(serverId: serverId, resource: resource),
        for (final template in state.resourceTemplates)
          McpResourceTemplateRow(template: template),
      ],
    );
  }
}
