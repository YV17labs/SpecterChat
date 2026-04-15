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
    @Default('') String authToken,
    @Default(true) bool enabled,
    @Default(false) bool connected,
    @Default([]) List<McpToolInfo> tools,
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
    @Default(true) bool enabled,
  }) = _McpToolInfo;

  factory McpToolInfo.fromJson(Map<String, dynamic> json) =>
      _$McpToolInfoFromJson(json);
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
