import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../models/app_settings.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/settings_provider.dart';

final _log = Logger('McpServerTile');

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
    final isConversationMode = enabledInConversation != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          server.connected ? Icons.cloud_done : Icons.cloud_off,
          size: 18,
          color: server.connected
              ? Colors.green
              : Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.4),
        ),
        title: Text(
          server.name,
          style:
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          server.url,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.5),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Per-conversation enable/disable toggle
            if (isConversationMode)
              Switch(
                value: enabledInConversation!,
                onChanged: onToggleConversation,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            // Connect/disconnect button
            IconButton(
              icon: Icon(
                server.connected ? Icons.link_off : Icons.link,
                size: 16,
              ),
              tooltip: server.connected ? 'Disconnect' : 'Connect',
              onPressed: () => _toggleConnection(ref, server),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                  minWidth: 32, minHeight: 32),
            ),
            // Remove button (global only)
            if (!isConversationMode)
              IconButton(
                icon: const Icon(Icons.delete, size: 16),
                tooltip: 'Remove',
                onPressed: () {
                  if (server.connected) {
                    ref.read(mcpServiceProvider).disconnect(server.id);
                  }
                  ref
                      .read(settingsProvider.notifier)
                      .removeMcpServer(server.id);
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 32, minHeight: 32),
              ),
          ],
        ),
        children: [
          if (server.tools.isNotEmpty)
            ...server.tools.map((tool) => ListTile(
                  dense: true,
                  leading: Checkbox(
                    value: tool.enabled,
                    onChanged: (enabled) {
                      final updatedTools = server.tools
                          .map((t) => t.name == tool.name
                              ? t.copyWith(enabled: enabled ?? true)
                              : t)
                          .toList();
                      ref
                          .read(settingsProvider.notifier)
                          .updateMcpServer(
                              server.copyWith(tools: updatedTools));
                    },
                  ),
                  title: Text(
                    tool.name,
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    tool.description,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )),
          if (server.connected && server.tools.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'No tools available',
                style: TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleConnection(
      WidgetRef ref, McpServerConfig server) async {
    final mcpService = ref.read(mcpServiceProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    if (server.connected) {
      mcpService.disconnect(server.id);
      settingsNotifier.updateMcpServer(
        server.copyWith(connected: false, tools: []),
      );
    } else {
      try {
        await connectMcpServer(
          server: server,
          mcpService: mcpService,
          notifier: settingsNotifier,
        );
      } catch (e, st) {
        _log.warning('Failed to connect to MCP server: ${server.name}', e, st);
        settingsNotifier.updateMcpServer(
          server.copyWith(connected: false),
        );
        if (ref.context.mounted) {
          ScaffoldMessenger.of(ref.context).showSnackBar(
            SnackBar(
              content: Text('Failed to connect: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }
}
