import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/app_settings.dart';
import '../../providers/llm_provider.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/mcp_service.dart';
import '../../utils/id_gen.dart';

class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key});

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  late TextEditingController _baseUrlController;
  late TextEditingController _apiKeyController;
  late TextEditingController _systemPromptController;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _baseUrlController =
        TextEditingController(text: settings.api.baseUrl);
    _apiKeyController =
        TextEditingController(text: settings.api.apiKey);
    _systemPromptController =
        TextEditingController(text: settings.defaultSystemPrompt);
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Section: API Connection
        _SectionHeader(title: 'API Connection'),
        const SizedBox(height: 8),
        _LabeledField(
          label: 'Base URL',
          child: TextField(
            controller: _baseUrlController,
            decoration: _inputDecoration(context, 'http://localhost:1234/v1'),
            onChanged: (value) {
              ref.read(settingsProvider.notifier).updateApi(
                    settings.api.copyWith(baseUrl: value),
                  );
            },
          ),
        ),
        const SizedBox(height: 8),
        _LabeledField(
          label: 'API Key (optional)',
          child: TextField(
            controller: _apiKeyController,
            decoration: _inputDecoration(context, 'sk-...'),
            obscureText: true,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).updateApi(
                    settings.api.copyWith(apiKey: value),
                  );
            },
          ),
        ),
        const SizedBox(height: 8),
        _ModelSelector(),

        const Divider(height: 32),

        // Section: Generation Parameters
        _SectionHeader(title: 'Generation'),
        const SizedBox(height: 8),
        _SliderField(
          label: 'Temperature',
          value: settings.generation.temperature,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .updateGeneration(
                  settings.generation.copyWith(temperature: v)),
        ),
        _SliderField(
          label: 'Top-P',
          value: settings.generation.topP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .updateGeneration(
                  settings.generation.copyWith(topP: v)),
        ),
        _LabeledField(
          label: 'Top-K',
          child: SizedBox(
            width: double.infinity,
            child: TextField(
              decoration: _inputDecoration(context, '0'),
              keyboardType: TextInputType.number,
              controller: TextEditingController(
                  text: settings.generation.topK.toString()),
              onSubmitted: (v) {
                final val = int.tryParse(v) ?? 0;
                ref.read(settingsProvider.notifier).updateGeneration(
                    settings.generation.copyWith(topK: val));
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        _LabeledField(
          label: 'Max Tokens',
          child: SizedBox(
            width: double.infinity,
            child: TextField(
              decoration: _inputDecoration(context, '4096'),
              keyboardType: TextInputType.number,
              controller: TextEditingController(
                  text: settings.generation.maxTokens.toString()),
              onSubmitted: (v) {
                final val = int.tryParse(v) ?? 4096;
                ref.read(settingsProvider.notifier).updateGeneration(
                    settings.generation.copyWith(maxTokens: val));
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        _SliderField(
          label: 'Repeat Penalty',
          value: settings.generation.repeatPenalty,
          min: 1,
          max: 2,
          divisions: 20,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .updateGeneration(
                  settings.generation.copyWith(repeatPenalty: v)),
        ),
        _SliderField(
          label: 'Frequency Penalty',
          value: settings.generation.frequencyPenalty,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .updateGeneration(
                  settings.generation.copyWith(frequencyPenalty: v)),
        ),
        _SliderField(
          label: 'Presence Penalty',
          value: settings.generation.presencePenalty,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .updateGeneration(
                  settings.generation.copyWith(presencePenalty: v)),
        ),

        const Divider(height: 32),

        // Section: System Prompt
        _SectionHeader(title: 'System Prompt'),
        const SizedBox(height: 8),
        TextField(
          controller: _systemPromptController,
          decoration: _inputDecoration(
              context, 'You are a helpful assistant...'),
          maxLines: 5,
          minLines: 3,
          onChanged: (value) {
            ref
                .read(settingsProvider.notifier)
                .updateDefaultSystemPrompt(value);
          },
        ),

        const Divider(height: 32),

        // Section: MCP Servers
        _SectionHeader(
          title: 'MCP Servers',
          trailing: IconButton(
            icon: const Icon(Icons.add, size: 18),
            tooltip: 'Add MCP Server',
            onPressed: () => _addMcpServer(),
          ),
        ),
        const SizedBox(height: 8),
        if (settings.mcpServers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                'No MCP servers configured',
                style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.4),
                  fontSize: 13,
                ),
              ),
            ),
          )
        else
          ...settings.mcpServers
              .map((server) => _McpServerTile(server: server)),
      ],
    );
  }

  InputDecoration _inputDecoration(
      BuildContext context, String hint) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color:
              Theme.of(context).colorScheme.outline.withOpacity(0.3),
        ),
      ),
      filled: true,
      fillColor:
          Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Future<void> _addMcpServer() async {
    final nameController = TextEditingController();
    final urlController =
        TextEditingController(text: 'http://localhost:3000/mcp');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add MCP Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration:
                  const InputDecoration(labelText: 'Server Name'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(labelText: 'URL'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result == true &&
        nameController.text.isNotEmpty &&
        urlController.text.isNotEmpty) {
      ref.read(settingsProvider.notifier).addMcpServer(
            McpServerConfig(
              id: generateId(),
              name: nameController.text,
              url: urlController.text,
            ),
          );
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 0.5,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          trailing!,
        ],
      ],
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;

  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _SliderField extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SliderField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withOpacity(0.6),
              ),
            ),
            const Spacer(),
            Text(
              value.toStringAsFixed(2),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape:
                const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _ModelSelector extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final modelsAsync = ref.watch(availableModelsProvider);

    return _LabeledField(
      label: 'Model',
      child: Row(
        children: [
          Expanded(
            child: modelsAsync.when(
              data: (models) {
                if (models.isEmpty) {
                  return const Text('No models available');
                }
                return DropdownButtonFormField<String>(
                  value: models.contains(settings.api.selectedModel)
                      ? settings.api.selectedModel
                      : null,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withOpacity(0.3),
                      ),
                    ),
                    filled: true,
                    fillColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                  ),
                  items: models
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(
                              m,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ))
                      .toList(),
                  onChanged: (model) {
                    if (model != null) {
                      ref.read(settingsProvider.notifier).updateApi(
                            settings.api
                                .copyWith(selectedModel: model),
                          );
                    }
                  },
                );
              },
              loading: () => const SizedBox(
                height: 36,
                child: Center(
                  child:
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
              error: (e, _) => Text(
                'Failed to load models',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Refresh models',
            onPressed: () =>
                ref.invalidate(availableModelsProvider),
          ),
        ],
      ),
    );
  }
}

class _McpServerTile extends ConsumerWidget {
  final McpServerConfig server;

  const _McpServerTile({required this.server});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          server.connected
              ? Icons.cloud_done
              : Icons.cloud_off,
          size: 18,
          color: server.connected
              ? Colors.green
              : Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withOpacity(0.4),
        ),
        title: Text(
          server.name,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          server.url,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withOpacity(0.5),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                server.connected ? Icons.link_off : Icons.link,
                size: 16,
              ),
              tooltip:
                  server.connected ? 'Disconnect' : 'Connect',
              onPressed: () =>
                  _toggleConnection(ref, server),
            ),
            IconButton(
              icon: const Icon(Icons.delete, size: 16),
              tooltip: 'Remove',
              onPressed: () {
                if (server.connected) {
                  ref
                      .read(mcpServiceProvider)
                      .disconnect(server.id);
                }
                ref
                    .read(settingsProvider.notifier)
                    .removeMcpServer(server.id);
              },
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
        final tools = await mcpService.connect(server);
        settingsNotifier.updateMcpServer(
          server.copyWith(connected: true, tools: tools),
        );
      } catch (e) {
        settingsNotifier.updateMcpServer(
          server.copyWith(connected: false),
        );
        // Show error snackbar
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
