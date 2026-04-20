import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../models/app_settings.dart';
import '../models/message.dart';
import 'i_mcp_service.dart';
import 'mcp/streamable_http_transport.dart' as transport;

export 'i_mcp_service.dart' show
    McpToolResult,
    McpContent,
    McpTextContent,
    McpImageContent,
    McpUnsupportedContent,
    McpPromptResult,
    McpPromptMessage,
    McpResourceResult,
    McpResourceContent,
    McpResourceTextContent,
    McpResourceBlobContent;

final _log = Logger('McpService');

const _clientInfo = mcp.Implementation(
  name: 'SpecterChat',
  version: '0.1.0',
);

/// Client for a single MCP server using Streamable HTTP transport.
///
/// Thin wrapper around [mcp.McpClient] that converts mcp_dart's native
/// types to SpecterChat's domain types. Accepts an optional [mcp.Transport]
/// for testability.
class McpClient {
  final String serverUrl;
  final Map<String, String> _headers;
  final mcp.McpClient _client;
  mcp.Transport? _transport;
  bool _initialized = false;
  String? _instructions;
  mcp.ServerCapabilities? _serverCaps;
  List<McpIcon> _serverIcons = const [];

  McpClient({
    required this.serverUrl,
    Map<String, String> headers = const {},
    mcp.Transport? transport,
  })  : _headers = headers,
        _transport = transport,
        _client = mcp.McpClient(_clientInfo);

  bool get isConnected => _initialized;
  String? get instructions => _instructions;
  List<McpIcon> get serverIcons => _serverIcons;
  mcp.ServerCapabilities? get serverCapabilities => _serverCaps;

  Future<void> initialize() async {
    _transport ??= transport.StreamableHttpClientTransport(
      Uri.parse(serverUrl),
      opts: transport.StreamableHttpClientTransportOptions(
        requestInit: _headers.isEmpty
            ? null
            : {'headers': <String, dynamic>{..._headers}},
        httpClient: http.Client(),
      ),
    );
    await _client.connect(_transport!);
    _instructions = _client.getInstructions();
    _serverCaps = _client.getServerCapabilities();
    _serverIcons = _client.getServerVersion()?.icons?.map(iconFromMcp).toList() ??
        const [];
    _initialized = true;
  }

  Future<List<McpToolInfo>> listTools() async {
    // Bypass mcp_dart's typed Tool parsing because its JsonSchema wrapper
    // drops unknown JSON Schema fields like $defs/$ref/anyOf-refs, which
    // some servers emit and the LLM backend requires to resolve the schema.
    final raw = await _client.request<_RawResult>(
      const mcp.JsonRpcListToolsRequest(id: -1),
      (json) => _RawResult(json),
    );

    final toolsJson = (raw.json['tools'] as List?) ?? const [];
    return toolsJson.map((t) {
      final tool = _asJsonMap(t);
      return McpToolInfo(
        name: tool['name'] as String,
        description: tool['description'] as String? ?? '',
        title: tool['title'] as String? ?? '',
        inputSchema:
            (tool['inputSchema'] as Map?)?.cast<String, dynamic>() ?? const {},
        annotations: tool['annotations'] == null
            ? null
            : McpToolAnnotations.fromJson(_asJsonMap(tool['annotations'])),
        icons: _iconListFromJson(tool['icons']),
      );
    }).toList();
  }

  Future<List<McpPrompt>> listPrompts() async {
    if (_serverCaps?.prompts == null) return const [];
    final raw = await _client.request<_RawResult>(
      mcp.JsonRpcListPromptsRequest(id: -1),
      (json) => _RawResult(json),
    );
    final promptsJson = (raw.json['prompts'] as List?) ?? const [];
    return promptsJson.map((p) => McpPrompt.fromJson(_asJsonMap(p))).toList();
  }

  Future<List<McpResource>> listResources() async {
    if (_serverCaps?.resources == null) return const [];
    final raw = await _client.request<_RawResult>(
      mcp.JsonRpcListResourcesRequest(id: -1),
      (json) => _RawResult(json),
    );
    final items = (raw.json['resources'] as List?) ?? const [];
    return items.map((r) => McpResource.fromJson(_asJsonMap(r))).toList();
  }

  Future<List<McpResourceTemplate>> listResourceTemplates() async {
    if (_serverCaps?.resources == null) return const [];
    final raw = await _client.request<_RawResult>(
      mcp.JsonRpcListResourceTemplatesRequest(id: -1),
      (json) => _RawResult(json),
    );
    final items = (raw.json['resourceTemplates'] as List?) ?? const [];
    return items
        .map((r) => McpResourceTemplate.fromJson(_asJsonMap(r)))
        .toList();
  }

  Future<McpPromptResult> getPrompt(
    String name, {
    Map<String, String> arguments = const {},
  }) async {
    try {
      final result = await _client.getPrompt(
        mcp.GetPromptRequest(name: name, arguments: arguments),
      );
      return McpPromptResult(
        description: result.description,
        messages: result.messages
            .map((m) => McpPromptMessage(
                  role: _promptRoleFromMcp(m.role),
                  content: [contentFromMcp(m.content)],
                ))
            .toList(),
      );
    } on mcp.McpError catch (e) {
      throw McpException(e.message, code: e.code);
    }
  }

  Future<McpResourceResult> readResource(String uri) async {
    try {
      final result = await _client.readResource(
        mcp.ReadResourceRequest(uri: uri),
      );
      return McpResourceResult(
        contents: result.contents.map(_resourceContentFromMcp).toList(),
      );
    } on mcp.McpError catch (e) {
      throw McpException(e.message, code: e.code);
    }
  }

  Future<McpToolResult> callTool(
      String name, Map<String, dynamic> arguments) async {
    try {
      final result = await _client.callTool(
        mcp.CallToolRequest(name: name, arguments: arguments),
      );
      return McpToolResult(
        content: result.content.map(contentFromMcp).toList(),
        isError: result.isError,
      );
    } on mcp.McpError catch (e) {
      throw McpException(e.message, code: e.code);
    }
  }

  void disconnect() {
    _initialized = false;
    // Fire-and-forget: transport close is async but callers expect sync.
    _client.close().catchError(
          (Object e, StackTrace st) =>
              _log.fine('Error closing MCP client: $e'),
        );
  }
}

/// Wraps a raw JSON-RPC result so we can pass it through mcp_dart's typed
/// [mcp.Protocol.request] API without losing fields that mcp_dart's typed
/// result classes don't know about (e.g. JSON Schema `$defs`, `$ref`).
class _RawResult implements mcp.BaseResultData {
  final Map<String, dynamic> json;

  _RawResult(this.json);

  @override
  Map<String, dynamic>? get meta =>
      (json['_meta'] as Map?)?.cast<String, dynamic>();

  @override
  Map<String, dynamic> toJson() => json;
}

// --- JSON → domain converters -----------------------------------------

/// Safely re-types a `dynamic` or `Map` coming out of JSON as the shape
/// that Freezed's generated `fromJson` factories expect.
Map<String, dynamic> _asJsonMap(Object? raw) =>
    (raw as Map).cast<String, dynamic>();

List<McpIcon> _iconListFromJson(Object? raw) {
  if (raw is! List) return const [];
  return raw.map((i) => McpIcon.fromJson(_asJsonMap(i))).toList();
}

// --- mcp_dart → domain converters -------------------------------------

MessageRole _promptRoleFromMcp(mcp.PromptMessageRole role) {
  return switch (role) {
    mcp.PromptMessageRole.user => MessageRole.user,
    mcp.PromptMessageRole.assistant => MessageRole.assistant,
  };
}

/// Converts an mcp_dart [mcp.McpIcon] to SpecterChat's [McpIcon].
McpIcon iconFromMcp(mcp.McpIcon icon) {
  return McpIcon(
    src: icon.src,
    mimeType: icon.mimeType,
    sizes: icon.sizes ?? const [],
    theme: icon.theme?.name,
  );
}

/// Converts an mcp_dart [mcp.Content] block to SpecterChat's [McpContent].
McpContent contentFromMcp(mcp.Content content) {
  return switch (content) {
    mcp.TextContent() => McpTextContent(content.text),
    mcp.ImageContent() => McpImageContent(
        base64Data: content.data,
        mimeType: content.mimeType,
      ),
    _ => McpUnsupportedContent(type: content.type, raw: content.toJson()),
  };
}

McpResourceContent _resourceContentFromMcp(mcp.ResourceContents c) {
  final json = c.toJson();
  final text = json['text'] as String?;
  if (text != null) {
    return McpResourceTextContent(
      uri: json['uri'] as String,
      mimeType: json['mimeType'] as String?,
      text: text,
    );
  }
  return McpResourceBlobContent(
    uri: json['uri'] as String,
    mimeType: json['mimeType'] as String?,
    base64Data: json['blob'] as String? ?? '',
  );
}

/// Factory function type for creating [McpClient] instances.
///
/// Allows injection of test doubles for [McpClient].
typedef McpClientFactory = McpClient Function(McpServerConfig config);

/// Manages multiple MCP server connections.
///
/// Accepts an optional [McpClientFactory] for testability.
class McpService implements IMcpService {
  final Map<String, McpClient> _clients = {};
  final McpClientFactory _clientFactory;

  McpService({McpClientFactory? clientFactory})
      : _clientFactory = clientFactory ??
            ((config) => McpClient(
                  serverUrl: config.url,
                  headers: config.headers,
                ));

  @override
  Future<McpConnectResult> connect(McpServerConfig config) async {
    final client = _clientFactory(config);
    try {
      await client.initialize();
      // Run the optional list fetches in parallel; each one is a no-op
      // when the server didn't advertise the matching capability.
      final results = await Future.wait([
        client.listTools(),
        client.listPrompts(),
        client.listResources(),
        client.listResourceTemplates(),
      ]);
      _clients[config.id] = client;
      return McpConnectResult(
        tools: results[0] as List<McpToolInfo>,
        prompts: results[1] as List<McpPrompt>,
        resources: results[2] as List<McpResource>,
        resourceTemplates: results[3] as List<McpResourceTemplate>,
        icons: client.serverIcons,
        instructions: client.instructions ?? '',
      );
    } catch (e, st) {
      _log.severe('Failed to connect MCP server: ${config.url}', e, st);
      client.disconnect();
      rethrow;
    }
  }

  @override
  void disconnect(String serverId) {
    _clients[serverId]?.disconnect();
    _clients.remove(serverId);
  }

  @override
  void disconnectAll() {
    for (final client in _clients.values) {
      client.disconnect();
    }
    _clients.clear();
  }

  @override
  bool isConnected(String serverId) {
    return _clients[serverId]?.isConnected ?? false;
  }

  @override
  Future<McpToolResult> callTool(
    String serverId,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final client = _clients[serverId];
    if (client == null) {
      throw McpException('Server $serverId not connected');
    }
    return client.callTool(toolName, arguments);
  }

  @override
  Future<McpPromptResult> getPrompt(
    String serverId,
    String name, {
    Map<String, String> arguments = const {},
  }) async {
    final client = _clients[serverId];
    if (client == null) {
      throw McpException('Server $serverId not connected');
    }
    return client.getPrompt(name, arguments: arguments);
  }

  @override
  Future<McpResourceResult> readResource(String serverId, String uri) async {
    final client = _clients[serverId];
    if (client == null) {
      throw McpException('Server $serverId not connected');
    }
    return client.readResource(uri);
  }

  /// Convert MCP tools to OpenAI function-calling format.
  static List<Map<String, dynamic>> toolsToOpenAiFormat(
      List<McpToolInfo> tools) {
    return tools
        .where((t) => t.enabled)
        .map((t) => {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.inputSchema,
              },
            })
        .toList();
  }
}

class McpException implements Exception {
  final String message;
  final int code;

  McpException(this.message, {this.code = -1});

  @override
  String toString() => 'McpException($code): $message';
}
