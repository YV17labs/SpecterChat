import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_settings.dart';
import 'conversation.dart';
import 'image_settings.dart';

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
    required ImageSettings image,
    required int contextLength,
    required int imageHistoryLimit,
    required List<String> enabledMcpServerIds,
  }) = _EffectiveSettings;

  /// Global defaults, used when no conversation is selected.
  factory EffectiveSettings.global(AppSettings global) => EffectiveSettings(
    systemPrompt: global.defaultSystemPrompt,
    generation: global.generation,
    image: global.image,
    contextLength: global.api.contextLength,
    imageHistoryLimit: global.api.imageHistoryLimit,
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
      image: overrides?.image ?? global.image,
      contextLength: overrides?.contextLength ?? global.api.contextLength,
      imageHistoryLimit:
          overrides?.imageHistoryLimit ?? global.api.imageHistoryLimit,
      enabledMcpServerIds: overrides?.enabledMcpServerIds ?? const [],
    );
  }
}
