import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_settings.dart' show McpToolInfo;

part 'request_context.freezed.dart';
part 'request_context.g.dart';

/// What a text request carries besides its messages and sampling
/// parameters: the system prompt as sent — the user's merged with the MCP
/// servers' instructions — and the definitions of the tools offered (icons
/// left out). Stored once per change in a conversation, referenced by
/// [GenerationStats.requestContextId].
@freezed
abstract class RequestContext with _$RequestContext {
  const factory RequestContext({
    @Default('') String systemPrompt,
    @Default(<McpToolInfo>[]) List<McpToolInfo> tools,
  }) = _RequestContext;

  factory RequestContext.fromJson(Map<String, dynamic> json) =>
      _$RequestContextFromJson(json);
}
