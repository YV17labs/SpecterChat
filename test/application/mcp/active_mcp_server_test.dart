import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/mcp/active_mcp_server.dart';
import 'package:specterchat/domain/models/app_settings.dart';

import '../../support/fakes.dart';

void main() {
  final servers = [
    activeServer(
      id: 'a',
      tools: [
        tool('search'),
        const McpToolInfo(
          name: 'off',
          description: '',
          inputSchema: {},
          enabled: false,
        ),
      ],
      instructions: 'Use search wisely.',
    ),
    activeServer(id: 'b', tools: [tool('search'), tool('shot')]),
  ];

  group('findServerForTool', () {
    test('returns the first server exposing the tool', () {
      expect(findServerForTool(servers, 'search'), 'a');
      expect(findServerForTool(servers, 'shot'), 'b');
    });

    test('ignores tools the user switched off', () {
      expect(findServerForTool(servers, 'off'), isNull);
    });

    test('returns null when unknown or list is empty', () {
      expect(findServerForTool(servers, 'nope'), isNull);
      expect(findServerForTool(const [], 'search'), isNull);
    });
  });

  test('enabledToolsOf flattens enabled tools in server order', () {
    expect(enabledToolsOf(servers).map((t) => t.name), [
      'search',
      'search',
      'shot',
    ]);
  });

  test('mergedInstructionsOf skips servers without instructions', () {
    expect(
      mergedInstructionsOf(servers),
      '## MCP Server: a\nUse search wisely.',
    );
    expect(mergedInstructionsOf(const []), isEmpty);
  });
}
