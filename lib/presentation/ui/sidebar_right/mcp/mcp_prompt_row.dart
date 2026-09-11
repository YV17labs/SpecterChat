import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/mcp/mcp_content_text.dart';
import '../../../../core/theme.dart';
import '../../../../domain/models/app_settings.dart';
import '../../../providers/mcp_provider.dart';
import 'mcp_section_widgets.dart';

class McpPromptRow extends ConsumerWidget {
  final String serverId;
  final McpPrompt prompt;

  const McpPromptRow({super.key, required this.serverId, required this.prompt});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = context.specterStyles;
    final description = prompt.description;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.text_snippet_outlined, size: 16),
      title: Text(
        firstNonEmpty([prompt.title, prompt.name]),
        style: styles.small,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: description == null || description.isEmpty
          ? null
          : Text(
              description,
              style: styles.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: IconButton(
        icon: const Icon(Icons.playlist_add, size: 16),
        tooltip: 'Insert in chat',
        onPressed: () => _insert(context, ref).ignore(),
      ),
      onTap: () => _insert(context, ref).ignore(),
    );
  }

  Future<void> _insert(BuildContext context, WidgetRef ref) {
    if (prompt.arguments.any((a) => a.required)) {
      showSnack(
        context,
        'This prompt requires arguments; argument input is not wired yet.',
      );
      return Future.value();
    }
    return injectMcpTextIntoChat(
      context,
      ref,
      load: () async => promptMessagesToText(
        await ref.read(mcpServiceProvider).getPrompt(serverId, prompt.name),
      ),
      emptyMessage: 'Prompt returned no text content.',
      failureLabel: 'Failed to load prompt',
    );
  }
}
