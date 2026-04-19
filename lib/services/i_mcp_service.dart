import '../models/app_settings.dart';
import '../models/message.dart';

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

/// Preserves any content type not yet handled (audio, video, resource…).
class McpUnsupportedContent extends McpContent {
  final String type;
  final Map<String, dynamic> raw;
  McpUnsupportedContent({required this.type, required this.raw});
}

/// Result of connecting to an MCP server.
class McpConnectResult {
  final List<McpToolInfo> tools;
  final List<McpPrompt> prompts;
  final List<McpResource> resources;
  final List<McpResourceTemplate> resourceTemplates;
  final List<McpIcon> icons;
  final String instructions;

  McpConnectResult({
    required this.tools,
    this.prompts = const [],
    this.resources = const [],
    this.resourceTemplates = const [],
    this.icons = const [],
    this.instructions = '',
  });
}

/// One message block returned by `prompts/get`. The MCP spec allows only
/// `user` or `assistant` roles here, but we reuse [MessageRole] so downstream
/// code does not juggle a second role enum.
class McpPromptMessage {
  final MessageRole role;
  final List<McpContent> content;

  McpPromptMessage({required this.role, required this.content});
}

/// Result of a `prompts/get` call.
class McpPromptResult {
  final String? description;
  final List<McpPromptMessage> messages;

  McpPromptResult({this.description, required this.messages});
}

/// Result of a `resources/read` call.
///
/// Each entry represents one content block: either text or a binary blob.
class McpResourceResult {
  final List<McpResourceContent> contents;

  McpResourceResult({required this.contents});
}

sealed class McpResourceContent {
  final String uri;
  final String? mimeType;
  McpResourceContent({required this.uri, this.mimeType});
}

class McpResourceTextContent extends McpResourceContent {
  final String text;
  McpResourceTextContent({
    required super.uri,
    super.mimeType,
    required this.text,
  });
}

class McpResourceBlobContent extends McpResourceContent {
  final String base64Data;
  McpResourceBlobContent({
    required super.uri,
    super.mimeType,
    required this.base64Data,
  });
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

  /// Fetch the rendered messages for a prompt template.
  Future<McpPromptResult> getPrompt(
    String serverId,
    String name, {
    Map<String, String> arguments,
  });

  /// Read the content of a resource by URI.
  Future<McpResourceResult> readResource(String serverId, String uri);
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
