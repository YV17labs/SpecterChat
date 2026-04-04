import '../models/app_settings.dart';

/// Result of an MCP tool call.
class McpToolResult {
  final List<McpContent> content;
  final bool isError;

  McpToolResult({required this.content, this.isError = false});
}

sealed class McpContent {}

class McpTextContent extends McpContent {
  final String text;
  McpTextContent(this.text);
}

class McpImageContent extends McpContent {
  final String base64Data;
  final String mimeType;
  McpImageContent({required this.base64Data, required this.mimeType});
}

/// Result of connecting to an MCP server.
class McpConnectResult {
  final List<McpToolInfo> tools;
  final String instructions;

  McpConnectResult({required this.tools, this.instructions = ''});
}

/// Contract for MCP (Model Context Protocol) service communication.
abstract interface class IMcpService {
  Future<McpConnectResult> connect(McpServerConfig config);
  void disconnect(String serverId);
  void disconnectAll();
  bool isConnected(String serverId);

  Future<McpToolResult> callTool(
    String serverId,
    String toolName,
    Map<String, dynamic> arguments,
  );
}

/// Find which server owns a given tool name.
String? findServerForTool(List<McpServerConfig> servers, String toolName) {
  for (final server in servers) {
    if (server.enabled && server.connected) {
      for (final tool in server.tools) {
        if (tool.name == toolName) {
          return server.id;
        }
      }
    }
  }
  return null;
}
