import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:logging/logging.dart';

import '../../models/app_settings.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/i_mcp_service.dart';

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
    final leadingIcon = _ServerIcon(
      icons: server.icons,
      connected: server.connected,
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: leadingIcon,
        title: Text(
          server.name,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
            if (isConversationMode)
              Switch(
                value: enabledInConversation!,
                onChanged: onToggleConversation,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            IconButton(
              icon: Icon(
                server.connected ? Icons.link_off : Icons.link,
                size: 16,
              ),
              tooltip: server.connected ? 'Disconnect' : 'Connect',
              onPressed: () => _toggleConnection(ref, server),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
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
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
          ],
        ),
        children: [
          _ToolsSection(server: server),
          _PromptsSection(server: server),
          _ResourcesSection(server: server),
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
        server.copyWith(
          connected: false,
          tools: [],
          prompts: [],
          resources: [],
          resourceTemplates: [],
          icons: [],
        ),
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

// --- Server icon -------------------------------------------------------

class _ServerIcon extends StatelessWidget {
  final List<McpIcon> icons;
  final bool connected;

  const _ServerIcon({required this.icons, required this.connected});

  @override
  Widget build(BuildContext context) {
    final iconWidget = _resolveIconWidget(context, icons);
    final base = iconWidget != null
        ? SizedBox.square(dimension: 20, child: iconWidget)
        : _fallbackIcon(context);

    return Tooltip(
      message: connected ? 'Connected' : 'Disconnected',
      child: SizedBox(
        width: 22,
        height: 22,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: Center(child: base)),
            Positioned(
              right: -2,
              bottom: -2,
              child: _StatusDot(connected: connected),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackIcon(BuildContext context) {
    return Icon(
      Icons.dns_outlined,
      size: 18,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool connected;

  const _StatusDot({required this.connected});

  @override
  Widget build(BuildContext context) {
    final color = connected ? const Color(0xFF22C55E) : const Color(0xFF6B7280);
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: surface, width: 1.5),
        boxShadow: connected
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.6),
                  blurRadius: 4,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Picks the best matching icon from a list and returns a renderable widget,
/// or `null` if no icon is usable. Prefers the icon whose `theme` matches the
/// current platform brightness; otherwise takes the first icon.
Widget? _resolveIconWidget(BuildContext context, List<McpIcon> icons) {
  if (icons.isEmpty) return null;
  final brightness = Theme.of(context).brightness;
  final wantedTheme = brightness == Brightness.dark ? 'dark' : 'light';
  final match = icons.firstWhere(
    (i) => i.theme == wantedTheme,
    orElse: () => icons.first,
  );
  return _widgetFromIcon(match);
}

/// Renders an [McpIcon] as a widget. Branches on mimeType because Flutter's
/// core `Image` widget decodes only raster formats (PNG/JPEG/WebP/BMP). SVG
/// data URIs must go through `flutter_svg` or they crash the image pipeline.
///
/// Decoded bytes are cached by `src` via [_decodedIconCache] so settings-panel
/// rebuilds don't re-decode on every frame.
Widget? _widgetFromIcon(McpIcon icon) {
  final src = icon.src;

  if (src.startsWith('data:')) {
    final cached = _getOrDecodeIcon(src);
    if (cached == null) return null;
    final mime = (icon.mimeType ?? cached.mimeType).toLowerCase();
    final isSvg = mime.contains('svg');
    if (isSvg) {
      return SvgPicture.memory(
        cached.bytes,
        placeholderBuilder: (_) => const SizedBox.shrink(),
      );
    }
    return Image.memory(
      cached.bytes,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  if (src.startsWith('http://') || src.startsWith('https://')) {
    final mime = (icon.mimeType ?? '').toLowerCase();
    final isSvg = mime.contains('svg') || src.toLowerCase().endsWith('.svg');
    if (isSvg) {
      return SvgPicture.network(
        src,
        placeholderBuilder: (_) => const SizedBox.shrink(),
      );
    }
    return Image.network(
      src,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
  return null;
}

class _DecodedIcon {
  final Uint8List bytes;
  final String mimeType;

  const _DecodedIcon(this.bytes, this.mimeType);
}

/// Bounded LRU cache for decoded MCP-server icon data URIs. Without a
/// cap, a long-running app that connects to many MCP servers would hold
/// every icon forever. `LinkedHashMap` keeps insertion order; on each
/// hit we re-insert to move the entry to the "most recent" slot.
const int _iconCacheMaxEntries = 64;
final Map<String, _DecodedIcon> _decodedIconCache = <String, _DecodedIcon>{};

_DecodedIcon? _getOrDecodeIcon(String src) {
  final hit = _decodedIconCache.remove(src);
  if (hit != null) {
    _decodedIconCache[src] = hit;
    return hit;
  }
  final decoded = _decodeDataUri(src);
  if (decoded == null) return null;
  _decodedIconCache[src] = decoded;
  if (_decodedIconCache.length > _iconCacheMaxEntries) {
    _decodedIconCache.remove(_decodedIconCache.keys.first);
  }
  return decoded;
}

_DecodedIcon? _decodeDataUri(String src) {
  try {
    final data = UriData.parse(src);
    return _DecodedIcon(data.contentAsBytes(), data.mimeType);
  } catch (_) {
    return null;
  }
}

/// First non-empty, non-null string in [candidates], or empty string.
/// Used to resolve a display name: prefer `title`, then an annotation title,
/// then `name`.
String _firstNonEmpty(List<String?> candidates) {
  for (final c in candidates) {
    if (c != null && c.isNotEmpty) return c;
  }
  return '';
}

// --- Tools section -----------------------------------------------------

class _ToolsSection extends ConsumerWidget {
  final McpServerConfig server;

  const _ToolsSection({required this.server});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (server.tools.isEmpty) {
      if (server.connected) {
        return const _EmptyHint(text: 'No tools available');
      }
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(label: 'Tools'),
        for (final tool in server.tools) _ToolRow(server: server, tool: tool),
      ],
    );
  }
}

class _ToolRow extends ConsumerWidget {
  final McpServerConfig server;
  final McpToolInfo tool;

  const _ToolRow({required this.server, required this.tool});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayName = _firstNonEmpty([
      tool.title,
      tool.annotations?.title,
      tool.name,
    ]);
    final description = tool.description;

    return ListTile(
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
              .updateMcpServer(server.copyWith(tools: updatedTools));
        },
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ..._annotationBadges(context, tool.annotations),
        ],
      ),
      subtitle: description.isEmpty
          ? null
          : Text(
              description,
              style: const TextStyle(fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }
}

List<Widget> _annotationBadges(BuildContext context, McpToolAnnotations? a) {
  if (a == null) return const [];
  final badges = <Widget>[];
  if (a.readOnlyHint) {
    badges.add(const _Badge(
      text: 'read-only',
      color: Colors.blueGrey,
      tooltip: 'Server says this tool does not modify state',
    ));
  } else if (a.destructiveHint) {
    badges.add(const _Badge(
      text: 'destructive',
      color: Colors.redAccent,
      tooltip: 'Server says this tool may destroy data',
    ));
  }
  if (a.idempotentHint) {
    badges.add(const _Badge(
      text: 'idempotent',
      color: Colors.teal,
      tooltip: 'Repeated calls with same args have no extra effect',
    ));
  }
  return badges;
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final String? tooltip;

  const _Badge({required this.text, required this.color, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (tooltip == null) return pill;
    return Tooltip(message: tooltip!, child: pill);
  }
}

// --- Prompts section ---------------------------------------------------

class _PromptsSection extends ConsumerWidget {
  final McpServerConfig server;

  const _PromptsSection({required this.server});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (server.prompts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(label: 'Prompts'),
        for (final prompt in server.prompts)
          _PromptRow(server: server, prompt: prompt),
      ],
    );
  }
}

class _PromptRow extends ConsumerWidget {
  final McpServerConfig server;
  final McpPrompt prompt;

  const _PromptRow({required this.server, required this.prompt});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayName = _firstNonEmpty([prompt.title, prompt.name]);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.text_snippet_outlined, size: 16),
      title: Text(
        displayName,
        style: const TextStyle(fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: (prompt.description?.isNotEmpty ?? false)
          ? Text(
              prompt.description!,
              style: const TextStyle(fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: IconButton(
        icon: const Icon(Icons.playlist_add, size: 16),
        tooltip: 'Insert in chat',
        onPressed: () => _insertPrompt(context, ref),
      ),
      onTap: () => _insertPrompt(context, ref),
    );
  }

  Future<void> _insertPrompt(BuildContext context, WidgetRef ref) async {
    if (prompt.arguments.any((a) => a.required)) {
      _snack(context,
          'This prompt requires arguments; argument input is not wired yet.');
      return;
    }
    try {
      final result = await ref.read(mcpServiceProvider).getPrompt(
            server.id,
            prompt.name,
          );
      if (!context.mounted) return;
      final text = _promptMessagesToText(result);
      if (text.trim().isEmpty) {
        _snack(context, 'Prompt returned no text content.');
        return;
      }
      ref.read(chatInputInjectionProvider.notifier).state = text;
    } catch (e, st) {
      _log.warning('getPrompt failed', e, st);
      if (!context.mounted) return;
      _snack(context, 'Failed to load prompt: $e');
    }
  }
}

String _promptMessagesToText(McpPromptResult result) {
  final buf = StringBuffer();
  for (final msg in result.messages) {
    for (final c in msg.content) {
      if (c is McpTextContent) {
        if (buf.isNotEmpty) buf.write('\n\n');
        buf.write(c.text);
      }
    }
  }
  return buf.toString();
}

// --- Resources section -------------------------------------------------

class _ResourcesSection extends ConsumerWidget {
  final McpServerConfig server;

  const _ResourcesSection({required this.server});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (server.resources.isEmpty && server.resourceTemplates.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(label: 'Resources'),
        for (final resource in server.resources)
          _ResourceRow(server: server, resource: resource),
        for (final template in server.resourceTemplates)
          _ResourceTemplateRow(template: template),
      ],
    );
  }
}

class _ResourceRow extends ConsumerWidget {
  final McpServerConfig server;
  final McpResource resource;

  const _ResourceRow({required this.server, required this.resource});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayName = _firstNonEmpty([resource.title, resource.name]);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.link, size: 16),
      title: Text(
        displayName,
        style: const TextStyle(fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        resource.uri,
        style: const TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.download, size: 16),
        tooltip: 'Attach content to chat',
        onPressed: () => _attachResource(context, ref),
      ),
      onTap: () => _attachResource(context, ref),
    );
  }

  Future<void> _attachResource(BuildContext context, WidgetRef ref) async {
    try {
      final result = await ref.read(mcpServiceProvider).readResource(
            server.id,
            resource.uri,
          );
      if (!context.mounted) return;
      final text = _resourceContentsToText(result, resource.uri);
      if (text.trim().isEmpty) {
        _snack(context, 'Resource returned no content.');
        return;
      }
      ref.read(chatInputInjectionProvider.notifier).state = text;
    } catch (e, st) {
      _log.warning('readResource failed', e, st);
      if (!context.mounted) return;
      _snack(context, 'Failed to read resource: $e');
    }
  }
}

class _ResourceTemplateRow extends StatelessWidget {
  final McpResourceTemplate template;

  const _ResourceTemplateRow({required this.template});

  @override
  Widget build(BuildContext context) {
    // Templates need URI parameter resolution which is not wired yet.
    return ListTile(
      dense: true,
      leading: const Icon(Icons.pattern, size: 16),
      title: Text(
        _firstNonEmpty([template.title, template.name]),
        style: const TextStyle(fontSize: 12),
      ),
      subtitle: Text(
        template.uriTemplate,
        style: const TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
        ),
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

String _resourceContentsToText(McpResourceResult result, String uri) {
  final buf = StringBuffer();
  for (final c in result.contents) {
    if (buf.isNotEmpty) buf.write('\n\n');
    switch (c) {
      case McpResourceTextContent():
        buf.write(c.text);
      case McpResourceBlobContent():
        buf.write('[Binary resource: ${c.uri}'
            '${c.mimeType != null ? " (${c.mimeType})" : ""}'
            ', ${c.base64Data.length} base64 chars]');
    }
  }
  return buf.toString();
}

// --- Shared bits -------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }
}

void _snack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
