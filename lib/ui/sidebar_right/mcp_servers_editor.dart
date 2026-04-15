import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../utils/id_gen.dart';

/// Modal dialog that lets the user edit the full MCP servers configuration
/// as raw JSON (Claude Desktop style). Returns the parsed server list on
/// Save, or null on Cancel.
class McpServersEditorDialog extends StatefulWidget {
  final List<McpServerConfig> initial;

  const McpServersEditorDialog({super.key, required this.initial});

  static Future<List<McpServerConfig>?> show(
    BuildContext context,
    List<McpServerConfig> initial,
  ) {
    return showDialog<List<McpServerConfig>>(
      context: context,
      builder: (_) => McpServersEditorDialog(initial: initial),
    );
  }

  @override
  State<McpServersEditorDialog> createState() => _McpServersEditorDialogState();
}

class _McpServersEditorDialogState extends State<McpServersEditorDialog> {
  static const _encoder = JsonEncoder.withIndent('  ');

  late final TextEditingController _controller;
  String? _error;
  List<McpServerConfig>? _parsed;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _encoder.convert(_serialize(widget.initial)));
    _validate();
    _controller.addListener(_validate);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _validate() {
    try {
      final json = jsonDecode(_controller.text);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Root must be a JSON object');
      }
      final parsed = _deserialize(json, widget.initial);
      setState(() {
        _parsed = parsed;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _parsed = null;
        _error = e is FormatException ? e.message : e.toString();
      });
    }
  }

  void _format() {
    try {
      final json = jsonDecode(_controller.text);
      _controller.text = _encoder.convert(json);
    } catch (_) {
      // Leave text alone if it can't parse — the error is already shown.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Edit MCP Servers',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    label: const Text('Format'),
                    onPressed: _format,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Edit the JSON below. The map key is the server name; each '
                'entry requires a "url" and may include a "headers" object.',
                style: TextStyle(
                  fontSize: 11,
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _error == null
                          ? theme.colorScheme.outlineVariant
                          : theme.colorScheme.error,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(12),
                      isCollapsed: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 32,
                child: _error == null
                    ? Text(
                        _parsed == null
                            ? ''
                            : '${_parsed!.length} server${_parsed!.length == 1 ? '' : 's'} ready',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      )
                    : Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.error,
                        ),
                      ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _parsed == null
                        ? null
                        : () => Navigator.of(context).pop(_parsed),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Map<String, dynamic> _serialize(List<McpServerConfig> servers) {
  return {
    'mcpServers': {
      for (final s in servers)
        s.name: {
          'url': s.url,
          if (s.headers.isNotEmpty) 'headers': s.headers,
          if (!s.enabled) 'enabled': false,
        },
    },
  };
}

/// Parse a Claude-Desktop-style `mcpServers` object into our server list,
/// preserving the existing `id` (and runtime state) for any server whose
/// name matches a prior entry. Throws [FormatException] on bad input.
List<McpServerConfig> _deserialize(
  Map<String, dynamic> json,
  List<McpServerConfig> existing,
) {
  final rawServers = json['mcpServers'];
  if (rawServers is! Map) {
    throw const FormatException('Root must contain an "mcpServers" object');
  }
  final byName = {for (final e in existing) e.name: e};
  final result = <McpServerConfig>[];
  rawServers.forEach((key, value) {
    final name = key.toString();
    if (value is! Map) {
      throw FormatException('Server "$name" must be an object');
    }
    final url = value['url'];
    if (url is! String || url.isEmpty) {
      throw FormatException('Server "$name" is missing a "url" string');
    }
    final rawHeaders = value['headers'];
    var headers = const <String, String>{};
    if (rawHeaders != null) {
      if (rawHeaders is! Map) {
        throw FormatException('Server "$name" headers must be an object');
      }
      final built = <String, String>{};
      for (final entry in rawHeaders.entries) {
        final v = entry.value;
        if (v is! String) {
          throw FormatException(
            'Server "$name" header "${entry.key}" must be a string',
          );
        }
        built[entry.key.toString()] = v;
      }
      headers = built;
    }
    final enabled = value['enabled'];
    if (enabled != null && enabled is! bool) {
      throw FormatException('Server "$name" "enabled" must be a boolean');
    }
    final prior = byName[name];
    result.add(McpServerConfig(
      id: prior?.id ?? generateId(),
      name: name,
      url: url,
      headers: headers,
      enabled: (enabled as bool?) ?? true,
      connected: prior?.connected ?? false,
      tools: prior?.tools ?? const [],
      instructions: prior?.instructions ?? '',
    ));
  });
  return result;
}
