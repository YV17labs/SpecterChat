import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:specterchat/models/app_settings.dart';
import 'package:specterchat/services/mcp_service.dart';

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
      final result = contentFromMcp(
        const mcp.AudioContent(data: 'b64', mimeType: 'audio/wav'),
      );
      expect(result, isA<McpUnsupportedContent>());
      final unsupported = result as McpUnsupportedContent;
      expect(unsupported.type, 'audio');
      expect(unsupported.raw['data'], 'b64');
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
