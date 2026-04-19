import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_settings.freezed.dart';
part 'app_settings.g.dart';

@freezed
abstract class ApiSettings with _$ApiSettings {
  const factory ApiSettings({
    @Default('http://localhost:1234/v1') String baseUrl,
    @Default('') String apiKey,
    @Default('') String selectedModel,
    @Default(32768) int contextLength,
  }) = _ApiSettings;

  factory ApiSettings.fromJson(Map<String, dynamic> json) =>
      _$ApiSettingsFromJson(json);
}

@freezed
abstract class GenerationSettings with _$GenerationSettings {
  const factory GenerationSettings({
    @Default(0.7) double temperature,
    @Default(1.0) double topP,
    @Default(0) int topK,
    @Default(4096) int maxTokens,
    @Default(1.0) double repeatPenalty,
    @Default(0.0) double minP,
    @Default(0.0) double frequencyPenalty,
    @Default(0.0) double presencePenalty,
  }) = _GenerationSettings;

  factory GenerationSettings.fromJson(Map<String, dynamic> json) =>
      _$GenerationSettingsFromJson(json);
}

@freezed
abstract class McpServerConfig with _$McpServerConfig {
  const factory McpServerConfig({
    required String id,
    required String name,
    required String url,
    @Default(<String, String>{}) Map<String, String> headers,
    @Default(true) bool enabled,
    @Default(false) bool connected,
    @Default([]) List<McpToolInfo> tools,
    @Default([]) List<McpPrompt> prompts,
    @Default([]) List<McpResource> resources,
    @Default([]) List<McpResourceTemplate> resourceTemplates,
    @Default([]) List<McpIcon> icons,
    @Default('') String instructions,
  }) = _McpServerConfig;

  factory McpServerConfig.fromJson(Map<String, dynamic> json) =>
      _$McpServerConfigFromJson(json);
}

@freezed
abstract class McpToolInfo with _$McpToolInfo {
  const factory McpToolInfo({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    @Default('') String title,
    @Default(true) bool enabled,
    McpToolAnnotations? annotations,
    @Default([]) List<McpIcon> icons,
  }) = _McpToolInfo;

  factory McpToolInfo.fromJson(Map<String, dynamic> json) =>
      _$McpToolInfoFromJson(json);
}

/// Tool annotation hints — non-authoritative behaviour signals.
///
/// All hints default to "most permissive" for safety: `readOnlyHint: false`
/// and `destructiveHint: true` mean we assume a tool may mutate or destroy
/// unless the server states otherwise.
@freezed
abstract class McpToolAnnotations with _$McpToolAnnotations {
  const factory McpToolAnnotations({
    String? title,
    @Default(false) bool readOnlyHint,
    @Default(true) bool destructiveHint,
    @Default(false) bool idempotentHint,
    @Default(true) bool openWorldHint,
  }) = _McpToolAnnotations;

  factory McpToolAnnotations.fromJson(Map<String, dynamic> json) =>
      _$McpToolAnnotationsFromJson(json);
}

/// Themed icon reference from an MCP server (server/tool/prompt/resource).
///
/// [src] is typically a `data:` URI or an HTTPS URL. [theme] is `light`
/// or `dark` when the server provides separate assets per appearance.
@freezed
abstract class McpIcon with _$McpIcon {
  const factory McpIcon({
    required String src,
    String? mimeType,
    @Default([]) List<String> sizes,
    String? theme,
  }) = _McpIcon;

  factory McpIcon.fromJson(Map<String, dynamic> json) =>
      _$McpIconFromJson(json);
}

@freezed
abstract class McpPromptArgument with _$McpPromptArgument {
  const factory McpPromptArgument({
    required String name,
    String? title,
    String? description,
    @Default(false) bool required,
  }) = _McpPromptArgument;

  factory McpPromptArgument.fromJson(Map<String, dynamic> json) =>
      _$McpPromptArgumentFromJson(json);
}

@freezed
abstract class McpPrompt with _$McpPrompt {
  const factory McpPrompt({
    required String name,
    String? title,
    String? description,
    @Default([]) List<McpPromptArgument> arguments,
    @Default([]) List<McpIcon> icons,
  }) = _McpPrompt;

  factory McpPrompt.fromJson(Map<String, dynamic> json) =>
      _$McpPromptFromJson(json);
}

@freezed
abstract class McpResource with _$McpResource {
  const factory McpResource({
    required String uri,
    required String name,
    String? title,
    String? description,
    String? mimeType,
    @Default([]) List<McpIcon> icons,
  }) = _McpResource;

  factory McpResource.fromJson(Map<String, dynamic> json) =>
      _$McpResourceFromJson(json);
}

@freezed
abstract class McpResourceTemplate with _$McpResourceTemplate {
  const factory McpResourceTemplate({
    required String uriTemplate,
    required String name,
    String? title,
    String? description,
    String? mimeType,
    @Default([]) List<McpIcon> icons,
  }) = _McpResourceTemplate;

  factory McpResourceTemplate.fromJson(Map<String, dynamic> json) =>
      _$McpResourceTemplateFromJson(json);
}

@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    @Default(ApiSettings()) ApiSettings api,
    @Default(GenerationSettings()) GenerationSettings generation,
    @Default('') String defaultSystemPrompt,
    @Default([]) List<McpServerConfig> mcpServers,
  }) = _AppSettings;

  factory AppSettings.fromJson(Map<String, dynamic> json) =>
      _$AppSettingsFromJson(json);
}
