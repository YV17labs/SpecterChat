import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/mcp_server_state.dart';

void main() {
  test('defaults to disconnected with nothing loaded', () {
    const s = McpServerState();
    expect(s.connected, isFalse);
    expect(s.connecting, isFalse);
    expect(s.tools, isEmpty);
    expect(s.enabledTools, isEmpty);
  });

  test('enabledTools filters switched-off tools', () {
    const s = McpServerState(
      status: McpConnectionStatus.connected,
      tools: [
        McpToolInfo(name: 'a', description: '', inputSchema: {}),
        McpToolInfo(
          name: 'b',
          description: '',
          inputSchema: {},
          enabled: false,
        ),
      ],
    );
    expect(s.connected, isTrue);
    expect(s.enabledTools.map((t) => t.name), ['a']);
  });
}
