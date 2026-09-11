import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_settings.dart';
import 'conversation.dart';

part 'effective_settings.freezed.dart';

/// Resolved settings for the active conversation.
///
/// Merges global [AppSettings] with per-conversation overrides.
/// When no conversation is selected, returns global defaults.
@freezed
abstract class EffectiveSettings with _$EffectiveSettings {
  const factory EffectiveSettings({
    required String systemPrompt,
    required GenerationSettings generation,
    required int contextLength,
    required List<String> enabledMcpServerIds,
  }) = _EffectiveSettings;

  /// Global defaults, used when no conversation is selected.
  factory EffectiveSettings.global(AppSettings global) => EffectiveSettings(
    systemPrompt: global.defaultSystemPrompt,
    generation: global.generation,
    contextLength: global.api.contextLength,
    enabledMcpServerIds: const [],
  );

  /// Global settings overlaid with [conversation]'s overrides.
  factory EffectiveSettings.resolve(
    AppSettings global,
    Conversation conversation,
  ) {
    final overrides = conversation.settings;
    return EffectiveSettings(
      systemPrompt:
          overrides?.systemPrompt ??
          conversation.systemPrompt ??
          global.defaultSystemPrompt,
      generation: overrides?.generation ?? global.generation,
      contextLength: overrides?.contextLength ?? global.api.contextLength,
      enabledMcpServerIds: overrides?.enabledMcpServerIds ?? const [],
    );
  }
}
