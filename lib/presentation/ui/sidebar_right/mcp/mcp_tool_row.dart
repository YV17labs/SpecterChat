import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../domain/models/app_settings.dart';
import '../../../providers/mcp_provider.dart';
import 'mcp_section_widgets.dart';

class McpToolRow extends ConsumerWidget {
  final String serverId;
  final McpToolInfo tool;

  const McpToolRow({super.key, required this.serverId, required this.tool});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = context.specterStyles;
    final displayName = firstNonEmpty([
      tool.title,
      tool.annotations?.title,
      tool.name,
    ]);

    return ListTile(
      dense: true,
      leading: Checkbox(
        value: tool.enabled,
        onChanged: (enabled) => ref
            .read(mcpServerStatesProvider.notifier)
            .setToolEnabled(
              serverId: serverId,
              toolName: tool.name,
              enabled: enabled ?? true,
            ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              style: styles.small,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ..._annotationBadges(tool.annotations),
        ],
      ),
      subtitle: tool.description.isEmpty
          ? null
          : Text(
              tool.description,
              style: styles.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }

  static List<Widget> _annotationBadges(McpToolAnnotations? a) {
    if (a == null) return const [];
    return [
      if (a.readOnlyHint)
        const McpBadge(
          text: 'read-only',
          color: Colors.blueGrey,
          tooltip: 'Server says this tool does not modify state',
        )
      else if (a.destructiveHint)
        const McpBadge(
          text: 'destructive',
          color: Colors.redAccent,
          tooltip: 'Server says this tool may destroy data',
        ),
      if (a.idempotentHint)
        const McpBadge(
          text: 'idempotent',
          color: Colors.teal,
          tooltip: 'Repeated calls with same args have no extra effect',
        ),
    ];
  }
}
