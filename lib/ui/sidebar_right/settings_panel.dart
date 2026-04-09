import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
import '../../models/conversation_settings.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/effective_settings_provider.dart';
import '../../providers/settings_provider.dart';
import '../../utils/id_gen.dart';
import '../widgets/settings_fields.dart';
import 'mcp_server_tile.dart';
import 'model_selector.dart';

class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key});

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  late TextEditingController _baseUrlController;
  late TextEditingController _apiKeyController;
  late TextEditingController _systemPromptController;
  late TextEditingController _topKController;
  late TextEditingController _maxTokensController;
  late TextEditingController _contextLengthController;

  bool _didSyncFromLoad = false;
  Timer? _conversationSettingsDebounce;

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
    _topKController =
        TextEditingController(text: settings.generation.topK.toString());
    _maxTokensController =
        TextEditingController(text: settings.generation.maxTokens.toString());
    _contextLengthController =
        TextEditingController(text: settings.api.contextLength.toString());

    // Sync controllers once when settings finish loading from disk.
    late final ProviderSubscription<AppSettings> sub;
    sub = ref.listenManual(settingsProvider, (prev, next) {
      if (!_didSyncFromLoad) {
        _didSyncFromLoad = true;
        _syncControllers();
        sub.close();
      }
    });
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _systemPromptController.dispose();
    _topKController.dispose();
    _maxTokensController.dispose();
    _contextLengthController.dispose();
    _conversationSettingsDebounce?.cancel();
    super.dispose();
  }

  /// Sync text controllers from the effective settings.
  void _syncControllers() {
    final effective = ref.read(effectiveSettingsProvider);
    final global = ref.read(settingsProvider);
    _baseUrlController.text = global.api.baseUrl;
    _apiKeyController.text = global.api.apiKey;
    _contextLengthController.text = effective.contextLength.toString();
    _systemPromptController.text = effective.systemPrompt;
    _topKController.text = effective.generation.topK.toString();
    _maxTokensController.text = effective.generation.maxTokens.toString();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final effective = ref.watch(effectiveSettingsProvider);
    final hasConversation = effective.hasConversation;

    // Re-sync text controllers when switching conversations and drop any
    // pending optimistic override (it belonged to the previous conversation).
    ref.listen(selectedConversationIdProvider, (prev, next) {
      if (prev != next) {
        _pendingConversationSettings = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncControllers();
        });
      }
    });

    // Optimistic display: while a conversation-scoped change is mid-debounce,
    // the database (and thus `effective`) hasn't caught up yet. Render from
    // the pending override so sliders track the user's drag in real time.
    final displayedGeneration =
        _pendingConversationSettings?.generation ?? effective.generation;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // --- Scope indicator ---
        if (hasConversation) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.chat_bubble_outline,
                    size: 14,
                    color: Theme.of(context).colorScheme.onPrimaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Editing settings for this conversation',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // --- API Connection (always global) ---
        const SectionHeader(title: 'API Connection'),
        const SizedBox(height: 8),
        LabeledField(
          label: 'Base URL',
          child: TextField(
            controller: _baseUrlController,
            decoration: settingsInputDecoration(
                context, 'http://localhost:1234/v1'),
            onChanged: (value) {
              ref.read(settingsProvider.notifier).updateApi(
                    settings.api.copyWith(baseUrl: value),
                  );
            },
          ),
        ),
        const SizedBox(height: 8),
        LabeledField(
          label: 'API Key (optional)',
          child: TextField(
            controller: _apiKeyController,
            decoration: settingsInputDecoration(context, 'sk-...'),
            obscureText: true,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).updateApi(
                    settings.api.copyWith(apiKey: value),
                  );
            },
          ),
        ),
        const SizedBox(height: 8),
        const ModelSelector(),
        const SizedBox(height: 8),
        LabeledField(
          label: 'Context Length',
          child: SizedBox(
            width: double.infinity,
            child: TextField(
              decoration: settingsInputDecoration(context, '32768'),
              keyboardType: TextInputType.number,
              controller: _contextLengthController,
              onChanged: (v) {
                final val = int.tryParse(v);
                if (val != null && val > 0) {
                  _updateContextLength(val);
                }
              },
            ),
          ),
        ),

        const Divider(height: 32),

        // --- Generation Parameters ---
        const SectionHeader(title: 'Generation'),
        const SizedBox(height: 8),
        SliderField(
          label: 'Temperature',
          value: displayedGeneration.temperature,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => _updateGeneration(
              displayedGeneration.copyWith(temperature: v)),
        ),
        SliderField(
          label: 'Top-P',
          value: displayedGeneration.topP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: (v) => _updateGeneration(
              displayedGeneration.copyWith(topP: v)),
        ),
        LabeledField(
          label: 'Top-K',
          child: SizedBox(
            width: double.infinity,
            child: TextField(
              decoration: settingsInputDecoration(context, '0'),
              keyboardType: TextInputType.number,
              controller: _topKController,
              onChanged: (v) {
                final val = int.tryParse(v);
                if (val != null) {
                  _updateGeneration(
                      displayedGeneration.copyWith(topK: val));
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        LabeledField(
          label: 'Max Tokens',
          child: SizedBox(
            width: double.infinity,
            child: TextField(
              decoration: settingsInputDecoration(context, '4096'),
              keyboardType: TextInputType.number,
              controller: _maxTokensController,
              onChanged: (v) {
                final val = int.tryParse(v);
                if (val != null) {
                  _updateGeneration(
                      displayedGeneration.copyWith(maxTokens: val));
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        SliderField(
          label: 'Min-P',
          value: displayedGeneration.minP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: (v) => _updateGeneration(
              displayedGeneration.copyWith(minP: v)),
        ),
        SliderField(
          label: 'Repeat Penalty',
          value: displayedGeneration.repeatPenalty,
          min: 1,
          max: 2,
          divisions: 20,
          onChanged: (v) => _updateGeneration(
              displayedGeneration.copyWith(repeatPenalty: v)),
        ),
        SliderField(
          label: 'Frequency Penalty',
          value: displayedGeneration.frequencyPenalty,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => _updateGeneration(
              displayedGeneration.copyWith(frequencyPenalty: v)),
        ),
        SliderField(
          label: 'Presence Penalty',
          value: displayedGeneration.presencePenalty,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => _updateGeneration(
              displayedGeneration.copyWith(presencePenalty: v)),
        ),

        const Divider(height: 32),

        // --- System Prompt ---
        const SectionHeader(title: 'System Prompt'),
        const SizedBox(height: 8),
        TextField(
          controller: _systemPromptController,
          decoration: settingsInputDecoration(
              context, 'You are a helpful assistant...'),
          style: const TextStyle(fontSize: 11, height: 1.4),
          maxLines: 10,
          minLines: 6,
          onChanged: (value) => _updateSystemPrompt(value),
        ),

        const Divider(height: 32),

        // --- MCP Servers ---
        SectionHeader(
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
                      .withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            ),
          )
        else
          ...settings.mcpServers.map((server) => McpServerTile(
                server: server,
                enabledInConversation: hasConversation
                    ? effective.enabledMcpServerIds.contains(server.id)
                    : null,
                onToggleConversation: hasConversation
                    ? (enabled) => _toggleMcpServerForConversation(
                        server.id, enabled)
                    : null,
              )),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Write helpers — route to conversation overrides or global settings
  // ---------------------------------------------------------------------------

  void _updateGeneration(GenerationSettings generation) {
    final conversation = ref.read(selectedConversationProvider);
    if (conversation != null) {
      _updateConversationSettings(
        (s) => s.copyWith(generation: generation),
      );
    } else {
      ref.read(settingsProvider.notifier).updateGeneration(generation);
    }
  }

  void _updateContextLength(int contextLength) {
    final conversation = ref.read(selectedConversationProvider);
    if (conversation != null) {
      _updateConversationSettings(
        (s) => s.copyWith(contextLength: contextLength),
      );
    } else {
      final settings = ref.read(settingsProvider);
      ref.read(settingsProvider.notifier).updateApi(
          settings.api.copyWith(contextLength: contextLength));
    }
  }

  void _updateSystemPrompt(String prompt) {
    final conversation = ref.read(selectedConversationProvider);
    if (conversation != null) {
      _updateConversationSettings(
        (s) => s.copyWith(systemPrompt: prompt),
      );
    } else {
      ref.read(settingsProvider.notifier).updateDefaultSystemPrompt(prompt);
    }
  }

  void _toggleMcpServerForConversation(String serverId, bool enabled) {
    _updateConversationSettings((s) {
      final ids = List<String>.from(s.enabledMcpServerIds ?? []);
      if (enabled) {
        if (!ids.contains(serverId)) ids.add(serverId);
      } else {
        ids.remove(serverId);
      }
      return s.copyWith(enabledMcpServerIds: ids);
    });
  }

  ConversationSettings? _pendingConversationSettings;

  void _updateConversationSettings(
      ConversationSettings Function(ConversationSettings) update) {
    final conversation = ref.read(selectedConversationProvider);
    if (conversation == null) return;
    final current =
        _pendingConversationSettings ??
        conversation.settings ??
        const ConversationSettings();
    final updated = update(current);
    // No-op guard: slider drags can fire onChanged at the same rounded
    // value repeatedly — skip the rebuild and timer re-arm in that case.
    if (updated == _pendingConversationSettings) return;
    // setState so the build picks up the new pending value immediately —
    // otherwise sliders snap back to the stale `effective` value while the
    // database write is still debounced.
    setState(() => _pendingConversationSettings = updated);
    _conversationSettingsDebounce?.cancel();
    _conversationSettingsDebounce =
        Timer(const Duration(milliseconds: 500), () {
      ref
          .read(conversationRepositoryProvider)
          .updateConversationSettings(conversation.id, updated);
      // Keep the pending override in place — it now matches what's in the
      // database, so there's no flicker, and clearing it before the Drift
      // stream re-emits would cause one.
    });
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
