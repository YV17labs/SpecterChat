import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/mcp/mcp_content_text.dart';
import '../../../../core/theme.dart';
import '../../../../domain/models/app_settings.dart';
import '../../../providers/mcp_provider.dart';
import 'mcp_section_widgets.dart';

class McpResourceRow extends ConsumerWidget {
  final String serverId;
  final McpResource resource;

  const McpResourceRow({
    super.key,
    required this.serverId,
    required this.resource,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = context.specterStyles;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.link, size: 16),
      title: Text(
        firstNonEmpty([resource.title, resource.name]),
        style: styles.small,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        resource.uri,
        style: styles.monospace.copyWith(fontSize: 10),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.download, size: 16),
        tooltip: 'Attach content to chat',
        onPressed: () => _attach(context, ref).ignore(),
      ),
      onTap: () => _attach(context, ref).ignore(),
    );
  }

  Future<void> _attach(BuildContext context, WidgetRef ref) {
    return injectMcpTextIntoChat(
      context,
      ref,
      load: () async => resourceContentsToText(
        await ref.read(mcpServiceProvider).readResource(serverId, resource.uri),
      ),
      emptyMessage: 'Resource returned no content.',
      failureLabel: 'Failed to read resource',
    );
  }
}

class McpResourceTemplateRow extends StatelessWidget {
  final McpResourceTemplate template;

  const McpResourceTemplateRow({super.key, required this.template});

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    // Templates need URI parameter resolution which is not wired yet.
    return ListTile(
      dense: true,
      leading: const Icon(Icons.pattern, size: 16),
      title: Text(
        firstNonEmpty([template.title, template.name]),
        style: styles.small,
      ),
      subtitle: Text(
        template.uriTemplate,
        style: styles.monospace.copyWith(fontSize: 10),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Tooltip(
        message: 'Resource templates require parameter input (coming soon)',
        child: Icon(Icons.info_outline, size: 14),
      ),
    );
  }
}
