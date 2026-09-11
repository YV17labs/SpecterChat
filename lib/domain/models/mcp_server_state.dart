import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_settings.dart';

part 'mcp_server_state.freezed.dart';

enum McpConnectionStatus { disconnected, connecting, connected }

/// Runtime state of one MCP server — what the server told us on
/// `initialize` and the list calls. Kept in memory only; the persisted
/// half is [McpServerConfig].
@freezed
abstract class McpServerState with _$McpServerState {
  const factory McpServerState({
    @Default(McpConnectionStatus.disconnected) McpConnectionStatus status,
    @Default([]) List<McpToolInfo> tools,
    @Default([]) List<McpPrompt> prompts,
    @Default([]) List<McpResource> resources,
    @Default([]) List<McpResourceTemplate> resourceTemplates,
    @Default([]) List<McpIcon> icons,
    @Default('') String instructions,

    /// Last connection failure, cleared on the next successful connect.
    String? lastError,
  }) = _McpServerState;

  const McpServerState._();

  bool get connected => status == McpConnectionStatus.connected;
  bool get connecting => status == McpConnectionStatus.connecting;

  /// Tools the user has not switched off in the sidebar.
  List<McpToolInfo> get enabledTools =>
      tools.where((t) => t.enabled).toList(growable: false);
}
