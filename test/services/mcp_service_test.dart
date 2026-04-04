import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:specterchat/models/app_settings.dart';
import 'package:specterchat/services/mcp_service.dart';

void main() {
  group('McpClient', () {
    late Dio dio;
    late DioAdapter dioAdapter;
    late McpClient client;

    setUp(() {
      dio = Dio(BaseOptions(baseUrl: 'http://mcp.test'));
      dioAdapter = DioAdapter(dio: dio);
      client = McpClient(serverUrl: 'http://mcp.test', dio: dio);
    });

    test('isConnected is false initially', () {
      expect(client.isConnected, false);
    });

    test('initialize sets isConnected to true', () async {
      // Mock initialize request
      dioAdapter.onPost(
        '',
        (server) => server.reply(200, {
          'jsonrpc': '2.0',
          'id': 'any',
          'result': {
            'protocolVersion': '2025-03-26',
            'capabilities': {},
            'serverInfo': {'name': 'test', 'version': '1.0'},
          },
        }),
        data: Matchers.any,
      );

      await client.initialize();
      expect(client.isConnected, true);
    });

    test('listTools returns parsed tools', () async {
      // First call for initialize
      dioAdapter.onPost(
        '',
        (server) => server.reply(200, {
          'jsonrpc': '2.0',
          'id': 'any',
          'result': {'protocolVersion': '2025-03-26'},
        }),
        data: Matchers.any,
      );

      await client.initialize();

      // Reset adapter for listTools
      dioAdapter.onPost(
        '',
        (server) => server.reply(200, {
          'jsonrpc': '2.0',
          'id': 'any',
          'result': {
            'tools': [
              {
                'name': 'search',
                'description': 'Search the web',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'query': {'type': 'string'}
                  },
                },
              },
            ],
          },
        }),
        data: Matchers.any,
      );

      final tools = await client.listTools();
      expect(tools.length, 1);
      expect(tools.first.name, 'search');
      expect(tools.first.description, 'Search the web');
    });

    test('callTool returns text content', () async {
      dioAdapter.onPost(
        '',
        (server) => server.reply(200, {
          'jsonrpc': '2.0',
          'id': 'any',
          'result': {
            'content': [
              {'type': 'text', 'text': 'result data'},
            ],
            'isError': false,
          },
        }),
        data: Matchers.any,
      );

      final result = await client.callTool('search', {'q': 'dart'});
      expect(result.isError, false);
      expect(result.content.length, 1);
      expect(result.content.first, isA<McpTextContent>());
      expect((result.content.first as McpTextContent).text, 'result data');
    });

    test('callTool returns image content', () async {
      dioAdapter.onPost(
        '',
        (server) => server.reply(200, {
          'jsonrpc': '2.0',
          'id': 'any',
          'result': {
            'content': [
              {
                'type': 'image',
                'data': 'base64data',
                'mimeType': 'image/png',
              },
            ],
          },
        }),
        data: Matchers.any,
      );

      final result =
          await client.callTool('screenshot', {});
      expect(result.content.first, isA<McpImageContent>());
      final img = result.content.first as McpImageContent;
      expect(img.base64Data, 'base64data');
      expect(img.mimeType, 'image/png');
    });

    test('throws McpException on JSON-RPC error', () async {
      dioAdapter.onPost(
        '',
        (server) => server.reply(200, {
          'jsonrpc': '2.0',
          'id': 'any',
          'error': {
            'code': -32600,
            'message': 'Invalid Request',
          },
        }),
        data: Matchers.any,
      );

      expect(
        () => client.callTool('bad', {}),
        throwsA(isA<McpException>()),
      );
    });

    test('disconnect resets state', () {
      client.disconnect();
      expect(client.isConnected, false);
    });
  });

  group('McpService', () {
    test('isConnected returns false for unknown server', () {
      final service = McpService();
      expect(service.isConnected('unknown'), false);
    });

    test('callTool throws when server not connected', () {
      final service = McpService();
      expect(
        () => service.callTool('srv-1', 'search', {}),
        throwsA(isA<McpException>()),
      );
    });

    test('disconnect removes server', () {
      final service = McpService();
      // Disconnecting a non-existent server should not throw
      service.disconnect('srv-1');
      expect(service.isConnected('srv-1'), false);
    });

    test('disconnectAll clears all connections', () {
      final service = McpService();
      service.disconnectAll();
      // Should not throw
    });

    group('toolsToOpenAiFormat', () {
      test('converts enabled tools', () {
        const tools = [
          McpToolInfo(
            name: 'search',
            description: 'Search',
            inputSchema: {'type': 'object'},
            enabled: true,
          ),
          McpToolInfo(
            name: 'disabled_tool',
            description: 'Disabled',
            inputSchema: {},
            enabled: false,
          ),
        ];
        final result = McpService.toolsToOpenAiFormat(tools);
        expect(result.length, 1);
        expect(result.first['type'], 'function');
        expect(result.first['function']['name'], 'search');
        expect(result.first['function']['description'], 'Search');
        expect(result.first['function']['parameters'], {'type': 'object'});
      });

      test('returns empty list when no tools enabled', () {
        const tools = [
          McpToolInfo(
            name: 'tool',
            description: 'desc',
            inputSchema: {},
            enabled: false,
          ),
        ];
        expect(McpService.toolsToOpenAiFormat(tools), isEmpty);
      });

      test('returns empty list for empty input', () {
        expect(McpService.toolsToOpenAiFormat([]), isEmpty);
      });
    });
  });

  group('McpException', () {
    test('toString includes code and message', () {
      final e = McpException('test', code: 42);
      expect(e.toString(), 'McpException(42): test');
    });

    test('default code is -1', () {
      final e = McpException('test');
      expect(e.code, -1);
    });
  });

  group('McpToolResult', () {
    test('isError defaults to false', () {
      final result = McpToolResult(content: []);
      expect(result.isError, false);
    });

    test('can be created with error flag', () {
      final result = McpToolResult(
        content: [McpTextContent('error')],
        isError: true,
      );
      expect(result.isError, true);
    });
  });
}
