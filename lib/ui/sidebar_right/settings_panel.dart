import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/app_settings.dart';
import '../../models/conversation_settings.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/effective_settings_provider.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/package_info_provider.dart';
import '../../providers/settings_provider.dart';
import '../widgets/settings_fields.dart';
import 'mcp_server_tile.dart';
import 'mcp_servers_editor.dart';
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

    // Listen to the Conversation object rather than its id so the sync
    // also fires on the null → Conversation(id) transition that happens
    // after cloning, once the Drift stream catches up.
    ref.listen(selectedConversationProvider, (prev, next) {
      if (prev?.id != next?.id) {
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
            icon: const Icon(Icons.edit, size: 18),
            tooltip: 'Edit MCP Servers (JSON)',
            onPressed: () => _editMcpServers(),
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

        const Divider(height: 32),

        // --- About ---
        const SectionHeader(title: 'About'),
        const SizedBox(height: 8),
        _AboutSection(),
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

  Future<void> _editMcpServers() async {
    final current = ref.read(settingsProvider).mcpServers;
    final result = await McpServersEditorDialog.show(context, current);
    if (result == null) return;

    // Disconnect any servers that were removed or whose id rotated — the
    // editor preserves ids by name, so id-based lookup catches both cases.
    final newIds = result.map((s) => s.id).toSet();
    final mcpService = ref.read(mcpServiceProvider);
    for (final prior in current) {
      if (prior.connected && !newIds.contains(prior.id)) {
        mcpService.disconnect(prior.id);
      }
    }

    ref.read(settingsProvider.notifier).replaceMcpServers(result);
  }
}

/// App identity footer: name, dynamic version, copyright, and a link to the
/// bundled open-source license list. The version is read from the running
/// bundle, so it always matches pubspec `version` with no manual updates.
class _AboutSection extends ConsumerWidget {
  // Attribution names the individual copyright holder alongside the trading
  // name: YV17labs is not a registered entity in every jurisdiction, so the
  // legally operative holder is the natural person.
  static const _copyright = 'Copyright © 2026 Yoann Vanitou (YV17labs)';
  static const _licenseLine = 'Open source — MIT License';
  static final _siteUri = Uri.parse('https://www.yv17labs.com');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final info = ref.watch(packageInfoProvider);
    final version = info.when(
      data: (i) => 'Version ${i.version} (build ${i.buildNumber})',
      loading: () => 'Version …',
      error: (_, _) => 'Version unknown',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SpecterChat',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(version, style: TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 2),
        Text(_copyright, style: TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 2),
        Text(_licenseLine, style: TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton(
              onPressed: () => _showLicenses(context, info.value),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Licenses', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: () =>
                  launchUrl(_siteUri, mode: LaunchMode.externalApplication),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('yv17labs.com', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  void _showLicenses(BuildContext context, PackageInfo? info) {
    showLicensePage(
      context: context,
      applicationName: 'SpecterChat',
      applicationVersion: info == null
          ? null
          : '${info.version} (build ${info.buildNumber})',
      applicationLegalese: '$_copyright\n$_licenseLine',
    );
  }
}
