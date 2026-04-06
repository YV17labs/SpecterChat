import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../models/app_settings.dart';
import '../utils/id_gen.dart';
import 'i_mcp_service.dart';

export 'i_mcp_service.dart' show
    McpToolResult, McpContent, McpTextContent, McpImageContent;

final _log = Logger('McpService');

Dio _defaultDioFactory(String baseUrl) {
  return Dio(BaseOptions(
    baseUrl: baseUrl,
    headers: {'Content-Type': 'application/json'},
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 2),
  ));
}

/// Client for a single MCP server using Streamable HTTP transport.
///
/// Accepts an optional [Dio] for testability. If not provided, creates
/// one internally via the [DioFactory].
class McpClient {
  final String serverUrl;
  final Dio _dio;
  String? _sessionId;
  bool _initialized = false;

  McpClient({required this.serverUrl, Dio? dio})
      : _dio = dio ?? _defaultDioFactory(serverUrl);

  bool get isConnected => _initialized;
  String? get instructions => _instructions;

  String? _instructions;

  Future<void> initialize() async {
    final result = await _sendRequest('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': {},
      'clientInfo': {
        'name': 'Specter Chat',
        'version': '0.1.0',
      },
    });

    _instructions = result['instructions'] as String?;
    _initialized = true;

    await _sendNotification('notifications/initialized', {});
  }

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

      return switch (type) {
        'text' => McpTextContent(item['text'] as String? ?? ''),
        'image' => McpImageContent(
            base64Data: item['data'] as String,
            mimeType: item['mimeType'] as String? ?? 'image/png',
          ),
        _ => McpUnsupportedContent(type: type, raw: item),
      };
    }).toList();

    return McpToolResult(content: content, isError: isError);
  }

  void disconnect() {
    _initialized = false;
    _sessionId = null;
    _dio.close();
  }

  Options _requestOptions() {
    final headers = <String, String>{
      'Accept': 'application/json, text/event-stream',
    };
    if (_sessionId != null) {
      headers['Mcp-Session-Id'] = _sessionId!;
    }
    return Options(headers: headers, responseType: ResponseType.plain);
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

    final response = await _dio.post(
      '',
      data: body,
      options: _requestOptions(),
    );

    final sessionHeader = response.headers.value('Mcp-Session-Id');
    if (sessionHeader != null) {
      _sessionId = sessionHeader;
    }

    final contentType =
        response.headers.value('content-type') ?? 'application/json';
    final data = _parseResponse(response.data as String, contentType);

    if (data.containsKey('error')) {
      final error = data['error'] as Map<String, dynamic>;
      throw McpException(
        error['message'] as String? ?? 'Unknown MCP error',
        code: error['code'] as int? ?? -1,
      );
    }
    return data['result'] as Map<String, dynamic>? ?? {};
  }

  /// Parse a response that may be JSON or SSE (text/event-stream).
  Map<String, dynamic> _parseResponse(String body, String contentType) {
    if (contentType.contains('text/event-stream')) {
      // Parse SSE: look for "data:" lines containing our JSON-RPC response.
      for (final line in body.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('data:')) {
          final jsonStr = trimmed.substring(5).trim();
          if (jsonStr.isEmpty) continue;
          try {
            final parsed = jsonDecode(jsonStr);
            if (parsed is Map<String, dynamic>) return parsed;
          } catch (e) {
            _log.fine('Skipping malformed SSE JSON: $jsonStr');
            continue;
          }
        }
      }
      return {};
    }
    // Plain JSON response.
    final parsed = jsonDecode(body);
    if (parsed is Map<String, dynamic>) return parsed;
    return {};
  }

  Future<void> _sendNotification(
      String method, Map<String, dynamic> params) async {
    final body = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };

    await _dio.post(
      '',
      data: body,
      options: _requestOptions(),
    );
  }
}

/// Factory function type for creating [McpClient] instances.
///
/// Allows injection of test doubles for [McpClient].
typedef McpClientFactory = McpClient Function(String serverUrl);

/// Manages multiple MCP server connections.
///
/// Accepts an optional [McpClientFactory] for testability.
class McpService implements IMcpService {
  final Map<String, McpClient> _clients = {};
  final McpClientFactory _clientFactory;

  McpService({McpClientFactory? clientFactory})
      : _clientFactory =
            clientFactory ?? ((url) => McpClient(serverUrl: url));

  @override
  Future<McpConnectResult> connect(McpServerConfig config) async {
    final client = _clientFactory(config.url);
    try {
      await client.initialize();
      final tools = await client.listTools();
      _clients[config.id] = client;
      return McpConnectResult(
        tools: tools,
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
