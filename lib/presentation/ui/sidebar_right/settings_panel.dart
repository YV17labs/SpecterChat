import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../domain/models/app_settings.dart';
import '../../../domain/models/conversation_settings.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/conversation_settings_provider.dart';
import '../../providers/effective_settings_provider.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/settings_provider.dart';
import '../widgets/settings_fields.dart';
import 'about_section.dart';
import 'mcp/mcp_server_tile.dart';
import 'mcp/mcp_servers_editor.dart';
import 'model_selector.dart';

/// Right sidebar. API connection and MCP server configuration are global;
/// generation, context length and system prompt edit the selected
/// conversation's overrides when one is selected, the global defaults
/// otherwise.
class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key});

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _systemPromptController;
  late final TextEditingController _topKController;
  late final TextEditingController _maxTokensController;
  late final TextEditingController _contextLengthController;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _baseUrlController = TextEditingController(text: settings.api.baseUrl);
    _apiKeyController = TextEditingController(text: settings.api.apiKey);
    _systemPromptController = TextEditingController(
      text: settings.defaultSystemPrompt,
    );
    _topKController = TextEditingController(
      text: settings.generation.topK.toString(),
    );
    _maxTokensController = TextEditingController(
      text: settings.generation.maxTokens.toString(),
    );
    _contextLengthController = TextEditingController(
      text: settings.api.contextLength.toString(),
    );

    // Sync controllers once when settings finish loading from disk.
    late final ProviderSubscription<AppSettings> sub;
    sub = ref.listenManual(settingsProvider, (prev, next) {
      _syncControllers();
      sub.close();
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
    super.dispose();
  }

  /// Text controllers are not reactive — refill them from the resolved
  /// settings whenever the underlying scope changes.
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
    final conversationId = ref.watch(conversationControllerProvider);

    // Listen to the Conversation object rather than its id so the sync
    // also fires on the null → Conversation(id) transition that happens
    // after cloning, once the database stream catches up.
    ref.listen(selectedConversationProvider, (prev, next) {
      if (prev?.id != next?.id) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncControllers();
        });
      }
    });

    // Optimistic display: while a conversation-scoped change is mid-debounce
    // the database (and thus `effective`) hasn't caught up yet. Render from
    // the pending override so sliders track the user's drag in real time.
    final pending = conversationId == null
        ? null
        : ref.watch(conversationSettingsProvider(conversationId));
    final generation = pending?.generation ?? effective.generation;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (conversationId != null) ...[
          const _ScopeBanner(),
          const SizedBox(height: 12),
        ],

        const SectionHeader(title: 'API Connection'),
        const SizedBox(height: 8),
        LabeledField(
          label: 'Base URL',
          child: TextField(
            controller: _baseUrlController,
            decoration: settingsInputDecoration(
              context,
              'http://localhost:1234/v1',
            ),
            onChanged: (value) => ref
                .read(settingsProvider.notifier)
                .updateApi(settings.api.copyWith(baseUrl: value)),
          ),
        ),
        const SizedBox(height: 8),
        LabeledField(
          label: 'API Key (optional)',
          child: TextField(
            controller: _apiKeyController,
            decoration: settingsInputDecoration(context, 'sk-...'),
            obscureText: true,
            onChanged: (value) => ref
                .read(settingsProvider.notifier)
                .updateApi(settings.api.copyWith(apiKey: value)),
          ),
        ),
        const SizedBox(height: 8),
        const ModelSelector(),
        const SizedBox(height: 8),
        LabeledField(
          label: 'Context Length',
          child: _IntField(
            controller: _contextLengthController,
            hint: '32768',
            onChanged: (v) {
              if (v > 0) _updateContextLength(conversationId, v);
            },
          ),
        ),

        const Divider(height: 32),

        const SectionHeader(title: 'Generation'),
        const SizedBox(height: 8),
        SliderField(
          label: 'Temperature',
          value: generation.temperature,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => _updateGeneration(
            conversationId,
            generation.copyWith(temperature: v),
          ),
        ),
        SliderField(
          label: 'Top-P',
          value: generation.topP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: (v) =>
              _updateGeneration(conversationId, generation.copyWith(topP: v)),
        ),
        LabeledField(
          label: 'Top-K',
          child: _IntField(
            controller: _topKController,
            hint: '0',
            onChanged: (v) =>
                _updateGeneration(conversationId, generation.copyWith(topK: v)),
          ),
        ),
        const SizedBox(height: 8),
        LabeledField(
          label: 'Max Tokens',
          child: _IntField(
            controller: _maxTokensController,
            hint: '4096',
            onChanged: (v) => _updateGeneration(
              conversationId,
              generation.copyWith(maxTokens: v),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SliderField(
          label: 'Min-P',
          value: generation.minP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: (v) =>
              _updateGeneration(conversationId, generation.copyWith(minP: v)),
        ),
        SliderField(
          label: 'Repeat Penalty',
          value: generation.repeatPenalty,
          min: 1,
          max: 2,
          divisions: 20,
          onChanged: (v) => _updateGeneration(
            conversationId,
            generation.copyWith(repeatPenalty: v),
          ),
        ),
        SliderField(
          label: 'Frequency Penalty',
          value: generation.frequencyPenalty,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => _updateGeneration(
            conversationId,
            generation.copyWith(frequencyPenalty: v),
          ),
        ),
        SliderField(
          label: 'Presence Penalty',
          value: generation.presencePenalty,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => _updateGeneration(
            conversationId,
            generation.copyWith(presencePenalty: v),
          ),
        ),

        const Divider(height: 32),

        const SectionHeader(title: 'System Prompt'),
        const SizedBox(height: 8),
        TextField(
          controller: _systemPromptController,
          decoration: settingsInputDecoration(
            context,
            'You are a helpful assistant...',
          ),
          style: const TextStyle(fontSize: 11, height: 1.4),
          maxLines: 10,
          minLines: 6,
          onChanged: (value) => _updateSystemPrompt(conversationId, value),
        ),

        const Divider(height: 32),

        SectionHeader(
          title: 'MCP Servers',
          trailing: IconButton(
            icon: const Icon(Icons.edit, size: 18),
            tooltip: 'Edit MCP Servers (JSON)',
            onPressed: () => _editMcpServers().ignore(),
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
                  color: context.specterStyles.textFaint,
                  fontSize: 13,
                ),
              ),
            ),
          )
        else
          for (final server in settings.mcpServers)
            McpServerTile(
              server: server,
              enabledInConversation: conversationId == null
                  ? null
                  : effective.enabledMcpServerIds.contains(server.id),
              onToggleConversation: conversationId == null
                  ? null
                  : (enabled) => _toggleMcpServerForConversation(
                      conversationId,
                      server.id,
                      enabled,
                    ),
            ),

        const Divider(height: 32),

        const SectionHeader(title: 'About'),
        const SizedBox(height: 8),
        const AboutSection(),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Write helpers — route to conversation overrides or global settings
  // ---------------------------------------------------------------------

  void _updateConversation(
    String conversationId,
    ConversationSettings Function(ConversationSettings) change,
  ) {
    ref
        .read(conversationSettingsProvider(conversationId).notifier)
        .update(change);
  }

  void _updateGeneration(String? conversationId, GenerationSettings g) {
    if (conversationId != null) {
      _updateConversation(conversationId, (s) => s.copyWith(generation: g));
    } else {
      ref.read(settingsProvider.notifier).updateGeneration(g);
    }
  }

  void _updateContextLength(String? conversationId, int contextLength) {
    if (conversationId != null) {
      _updateConversation(
        conversationId,
        (s) => s.copyWith(contextLength: contextLength),
      );
    } else {
      final api = ref.read(settingsProvider).api;
      ref
          .read(settingsProvider.notifier)
          .updateApi(api.copyWith(contextLength: contextLength));
    }
  }

  void _updateSystemPrompt(String? conversationId, String prompt) {
    if (conversationId != null) {
      _updateConversation(
        conversationId,
        (s) => s.copyWith(systemPrompt: prompt),
      );
    } else {
      ref.read(settingsProvider.notifier).updateDefaultSystemPrompt(prompt);
    }
  }

  void _toggleMcpServerForConversation(
    String conversationId,
    String serverId,
    bool enabled,
  ) {
    _updateConversation(conversationId, (s) {
      final ids = {...?s.enabledMcpServerIds};
      if (enabled) {
        ids.add(serverId);
      } else {
        ids.remove(serverId);
      }
      return s.copyWith(enabledMcpServerIds: ids.toList());
    });
  }

  Future<void> _editMcpServers() async {
    final current = ref.read(settingsProvider).mcpServers;
    final result = await McpServersEditorDialog.show(context, current);
    if (result == null || !mounted) return;
    // Servers that were removed, or whose id rotated, lose their
    // connection — the editor preserves ids by name, so an id-based check
    // catches both cases.
    ref
        .read(mcpServerStatesProvider.notifier)
        .disconnectMissing(result.map((s) => s.id));
    ref.read(settingsProvider.notifier).replaceMcpServers(result);
  }
}

class _ScopeBanner extends StatelessWidget {
  const _ScopeBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 14,
            color: cs.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Editing settings for this conversation',
              style: TextStyle(fontSize: 12, color: cs.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Numeric text field; [onChanged] only fires for parseable integers.
class _IntField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<int> onChanged;

  const _IntField({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextField(
        decoration: settingsInputDecoration(context, hint),
        keyboardType: TextInputType.number,
        controller: controller,
        onChanged: (v) {
          final parsed = int.tryParse(v);
          if (parsed != null) onChanged(parsed);
        },
      ),
    );
  }
}
