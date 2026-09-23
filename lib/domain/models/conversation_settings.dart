import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_settings.dart';
import 'image_settings.dart';

part 'conversation_settings.freezed.dart';
part 'conversation_settings.g.dart';

/// Per-conversation settings overrides.
///
/// Every field is nullable — `null` means "inherit from global [AppSettings]".
@freezed
abstract class ConversationSettings with _$ConversationSettings {
  const factory ConversationSettings({
    String? systemPrompt,
    GenerationSettings? generation,

    /// Image-model options; `null` inherits the global [AppSettings.image].
    ImageSettings? image,
    int? contextLength,

    /// Images kept from the history; `null` inherits the global
    /// [ApiSettings.imageHistoryLimit], `0` sends every one of them.
    int? imageHistoryLimit,

    /// IDs of MCP servers the user explicitly enabled for this conversation.
    /// `null` means no override (no servers enabled); `[]` means explicitly none.
    List<String>? enabledMcpServerIds,
  }) = _ConversationSettings;

  factory ConversationSettings.fromJson(Map<String, dynamic> json) =>
      _$ConversationSettingsFromJson(json);
}
