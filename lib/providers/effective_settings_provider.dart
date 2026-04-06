import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import 'conversation_provider.dart';
import 'settings_provider.dart';

/// Resolved settings for the active conversation.
///
/// Merges global [AppSettings] with per-conversation overrides.
/// When no conversation is selected, returns global defaults.
@immutable
class EffectiveSettings {
  final String systemPrompt;
  final GenerationSettings generation;
  final List<String> enabledMcpServerIds;

  /// `true` when a conversation is selected (settings are per-conversation).
  final bool hasConversation;

  const EffectiveSettings({
    required this.systemPrompt,
    required this.generation,
    required this.enabledMcpServerIds,
    required this.hasConversation,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EffectiveSettings &&
          systemPrompt == other.systemPrompt &&
          generation == other.generation &&
          hasConversation == other.hasConversation &&
          listEquals(enabledMcpServerIds, other.enabledMcpServerIds);

  @override
  int get hashCode => Object.hash(
        systemPrompt,
        generation,
        hasConversation,
        Object.hashAll(enabledMcpServerIds),
      );
}

final effectiveSettingsProvider = Provider<EffectiveSettings>((ref) {
  final global = ref.watch(settingsProvider);
  final conversation = ref.watch(selectedConversationProvider);

  if (conversation == null) {
    return EffectiveSettings(
      systemPrompt: global.defaultSystemPrompt,
      generation: global.generation,
      enabledMcpServerIds: const [],
      hasConversation: false,
    );
  }

  final overrides = conversation.settings;

  return EffectiveSettings(
    systemPrompt: overrides?.systemPrompt ??
        conversation.systemPrompt ??
        global.defaultSystemPrompt,
    generation: overrides?.generation ?? global.generation,
    enabledMcpServerIds: overrides?.enabledMcpServerIds ?? const [],
    hasConversation: true,
  );
});
