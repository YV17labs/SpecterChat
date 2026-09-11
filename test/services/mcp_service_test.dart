import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:specterchat/models/app_settings.dart';
import 'package:specterchat/services/mcp_service.dart';

const _server = McpServerConfig(
  id: 'srv-1',
  name: 'ghostdesk',
  url: 'http://localhost:3001/mcp',
);

/// A client whose session the server drops after [callsBeforeLoss] calls.
/// Every instance the factory hands out is recorded, so a test can tell a
/// silent re-initialize from a retry on the same dead client.
class _SessionLosingClient extends McpClient {
  final int callsBeforeLoss;
  final List<String> calls = [];
  bool initialized = false;
  bool disconnected = false;

  _SessionLosingClient(this.callsBeforeLoss) : super(serverUrl: _server.url);

  @override
  bool get isConnected => initialized && !disconnected;

  @override
  Future<void> initialize() async => initialized = true;

  @override
  Future<List<McpToolInfo>> listTools() async => const [];

  @override
  Future<McpToolResult> callTool(
      String name, Map<String, dynamic> arguments) async {
    calls.add(name);
    if (calls.length > callsBeforeLoss) {
      throw McpSessionLostException('Session dead-session no longer exists');
    }
    return McpToolResult(content: [McpTextContent('ok from $name')]);
  }

  @override
  void disconnect() => disconnected = true;
}

void main() {
  group('contentFromMcp', () {
    test('converts TextContent', () {
      final result = contentFromMcp(const mcp.TextContent(text: 'hello'));
      expect(result, isA<McpTextContent>());
      expect((result as McpTextContent).text, 'hello');
    });

    test('converts ImageContent', () {
      final result = contentFromMcp(
        const mcp.ImageContent(data: 'b64data', mimeType: 'image/png'),
      );
      expect(result, isA<McpImageContent>());
      final img = result as McpImageContent;
      expect(img.base64Data, 'b64data');
      expect(img.mimeType, 'image/png');
    });

    test('falls back to UnsupportedContent for unhandled types', () {
      // mcp_dart validates base64 in Content.toJson(), so the fixture must be
      // real base64 — 'YjY0' decodes to 'b64'.
      final result = contentFromMcp(
        const mcp.AudioContent(data: 'YjY0', mimeType: 'audio/wav'),
      );
      expect(result, isA<McpUnsupportedContent>());
      final unsupported = result as McpUnsupportedContent;
      expect(unsupported.type, 'audio');
      expect(unsupported.raw['data'], 'YjY0');
      expect(unsupported.raw['mimeType'], 'audio/wav');
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

    test('getPrompt throws when server not connected', () {
      final service = McpService();
      expect(
        () => service.getPrompt('srv-1', 'system_prompt'),
        throwsA(isA<McpException>()),
      );
    });

    test('readResource throws when server not connected', () {
      final service = McpService();
      expect(
        () => service.readResource('srv-1', 'ghostdesk://apps'),
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

    group('when the server drops the session', () {
      test('callTool re-initializes once and replays the call', () async {
        final made = <_SessionLosingClient>[];
        final service = McpService(clientFactory: (_) {
          // The first client survives exactly one call; its replacement
          // never loses its session.
          final client = _SessionLosingClient(made.isEmpty ? 1 : 1 << 30);
          made.add(client);
          return client;
        });
        await service.connect(_server);
        await service.callTool('srv-1', 'screen_shot', {});

        final result = await service.callTool('srv-1', 'app_list', {});

        expect((result.content.single as McpTextContent).text,
            'ok from app_list');
        expect(made, hasLength(2), reason: 'one fresh client, no more');
        expect(made.first.calls, ['screen_shot', 'app_list']);
        expect(made.first.disconnected, isTrue);
        expect(made.last.calls, ['app_list'], reason: 'replayed, not lost');
        expect(service.isConnected('srv-1'), isTrue);
      });

      test('a session lost right after re-initializing is not retried again',
          () async {
        final made = <_SessionLosingClient>[];
        final service = McpService(clientFactory: (_) {
          final client = _SessionLosingClient(0);
          made.add(client);
          return client;
        });
        await service.connect(_server);

        await expectLater(
          service.callTool('srv-1', 'screen_shot', {}),
          throwsA(isA<McpSessionLostException>()),
        );
        expect(made, hasLength(2), reason: 'exactly one recovery attempt');
      });
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
