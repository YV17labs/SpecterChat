import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_settings.dart';

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

    /// IDs of MCP servers the user explicitly enabled for this conversation.
    /// `null` means no override (no servers enabled); `[]` means explicitly none.
    List<String>? enabledMcpServerIds,
  }) = _ConversationSettings;

  factory ConversationSettings.fromJson(Map<String, dynamic> json) =>
      _$ConversationSettingsFromJson(json);
}
