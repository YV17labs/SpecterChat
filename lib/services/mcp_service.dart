import 'dart:convert';

import 'package:dio/dio.dart';
import '../models/app_settings.dart';
import '../utils/id_gen.dart';

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

/// Client for a single MCP server using Streamable HTTP transport.
class McpClient {
  final String serverUrl;
  final Dio _dio;
  String? _sessionId;
  bool _initialized = false;

  McpClient({required this.serverUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: serverUrl,
          headers: {'Content-Type': 'application/json'},
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 2),
        ));

  bool get isConnected => _initialized;

  /// Initialize the MCP connection.
  Future<void> initialize() async {
    final response = await _sendRequest('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': {},
      'clientInfo': {
        'name': 'Specter Chat',
        'version': '0.1.0',
      },
    });

    _initialized = true;

    // Send initialized notification
    await _sendNotification('notifications/initialized', {});
  }

  /// List available tools from the server.
  Future<List<McpToolInfo>> listTools() async {
    final response = await _sendRequest('tools/list', {});
    final tools = (response['tools'] as List?) ?? [];

    return tools.map((t) {
      final tool = t as Map<String, dynamic>;
      return McpToolInfo(
        name: tool['name'] as String,
        description: tool['description'] as String? ?? '',
        inputSchema: tool['inputSchema'] as Map<String, dynamic>? ?? {},
      );
    }).toList();
  }

  /// Call a tool on the MCP server.
  Future<McpToolResult> callTool(
      String name, Map<String, dynamic> arguments) async {
    final response = await _sendRequest('tools/call', {
      'name': name,
      'arguments': arguments,
    });

    final contentList = (response['content'] as List?) ?? [];
    final isError = response['isError'] as bool? ?? false;

    final content = contentList.map((c) {
      final item = c as Map<String, dynamic>;
      final type = item['type'] as String? ?? 'text';

      if (type == 'image') {
        return McpImageContent(
          base64Data: item['data'] as String,
          mimeType: item['mimeType'] as String? ?? 'image/png',
        );
      }
      return McpTextContent(item['text'] as String? ?? '');
    }).toList();

    return McpToolResult(content: content, isError: isError);
  }

  /// Disconnect from the server.
  void disconnect() {
    _initialized = false;
    _sessionId = null;
    _dio.close();
  }

  Future<Map<String, dynamic>> _sendRequest(
      String method, Map<String, dynamic> params) async {
    final id = generateId();
    final body = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };

    final headers = <String, String>{};
    if (_sessionId != null) {
      headers['Mcp-Session-Id'] = _sessionId!;
    }

    final response = await _dio.post(
      '',
      data: body,
      options: Options(headers: headers),
    );

    // Capture session ID from response
    final sessionHeader = response.headers.value('Mcp-Session-Id');
    if (sessionHeader != null) {
      _sessionId = sessionHeader;
    }

    final data = response.data;
    if (data is Map<String, dynamic>) {
      if (data.containsKey('error')) {
        final error = data['error'] as Map<String, dynamic>;
        throw McpException(
          error['message'] as String? ?? 'Unknown MCP error',
          code: error['code'] as int? ?? -1,
        );
      }
      return data['result'] as Map<String, dynamic>? ?? {};
    }

    return {};
  }

  Future<void> _sendNotification(
      String method, Map<String, dynamic> params) async {
    final body = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };

    final headers = <String, String>{};
    if (_sessionId != null) {
      headers['Mcp-Session-Id'] = _sessionId!;
    }

    await _dio.post(
      '',
      data: body,
      options: Options(headers: headers),
    );
  }
}

/// Manages multiple MCP server connections.
class McpService {
  final Map<String, McpClient> _clients = {};

  /// Connect to an MCP server.
  Future<List<McpToolInfo>> connect(McpServerConfig config) async {
    final client = McpClient(serverUrl: config.url);
    try {
      await client.initialize();
      final tools = await client.listTools();
      _clients[config.id] = client;
      return tools;
    } catch (e) {
      client.disconnect();
      rethrow;
    }
  }

  /// Disconnect from an MCP server.
  void disconnect(String serverId) {
    _clients[serverId]?.disconnect();
    _clients.remove(serverId);
  }

  /// Disconnect from all servers.
  void disconnectAll() {
    for (final client in _clients.values) {
      client.disconnect();
    }
    _clients.clear();
  }

  /// Check if a server is connected.
  bool isConnected(String serverId) {
    return _clients[serverId]?.isConnected ?? false;
  }

  /// Call a tool, routing to the correct server.
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
