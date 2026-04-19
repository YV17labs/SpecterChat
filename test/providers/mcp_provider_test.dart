import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:specterchat/models/app_settings.dart';
import 'package:specterchat/providers/effective_settings_provider.dart';
import 'package:specterchat/providers/mcp_provider.dart';
import 'package:specterchat/providers/settings_provider.dart';
import 'package:specterchat/services/i_mcp_service.dart';

EffectiveSettings _effective({required List<String> enabledMcpServerIds}) {
  return EffectiveSettings(
    systemPrompt: '',
    generation: const GenerationSettings(),
    contextLength: 32768,
    enabledMcpServerIds: enabledMcpServerIds,
    hasConversation: true,
  );
}

void main() {
  group('findServerForTool', () {
    test('returns server id when tool found', () {
      const servers = [
        McpServerConfig(
          id: 'srv-1',
          name: 'Server 1',
          url: 'http://localhost:3001',
          enabled: true,
          connected: true,
          tools: [
            McpToolInfo(
              name: 'search',
              description: 'Search',
              inputSchema: {},
            ),
          ],
        ),
        McpServerConfig(
          id: 'srv-2',
          name: 'Server 2',
          url: 'http://localhost:3002',
          enabled: true,
          connected: true,
          tools: [
            McpToolInfo(
              name: 'screenshot',
              description: 'Screenshot',
              inputSchema: {},
            ),
          ],
        ),
      ];

      expect(findServerForTool(servers, 'search'), 'srv-1');
      expect(findServerForTool(servers, 'screenshot'), 'srv-2');
    });

    test('returns null when tool not found', () {
      const servers = [
        McpServerConfig(
          id: 'srv-1',
          name: 'Server 1',
          url: 'http://localhost:3001',
          enabled: true,
          connected: true,
          tools: [
            McpToolInfo(
              name: 'search',
              description: 'Search',
              inputSchema: {},
            ),
          ],
        ),
      ];

      expect(findServerForTool(servers, 'nonexistent'), isNull);
    });

    test('ignores disabled servers', () {
      const servers = [
        McpServerConfig(
          id: 'srv-1',
          name: 'Server 1',
          url: 'http://localhost:3001',
          enabled: false,
          connected: true,
          tools: [
            McpToolInfo(
              name: 'search',
              description: 'Search',
              inputSchema: {},
            ),
          ],
        ),
      ];

      expect(findServerForTool(servers, 'search'), isNull);
    });

    test('ignores disconnected servers', () {
      const servers = [
        McpServerConfig(
          id: 'srv-1',
          name: 'Server 1',
          url: 'http://localhost:3001',
          enabled: true,
          connected: false,
          tools: [
            McpToolInfo(
              name: 'search',
              description: 'Search',
              inputSchema: {},
            ),
          ],
        ),
      ];

      expect(findServerForTool(servers, 'search'), isNull);
    });

    test('returns first match when tool on multiple servers', () {
      const servers = [
        McpServerConfig(
          id: 'srv-1',
          name: 'Server 1',
          url: 'http://localhost:3001',
          enabled: true,
          connected: true,
          tools: [
            McpToolInfo(
              name: 'search',
              description: 'Search v1',
              inputSchema: {},
            ),
          ],
        ),
        McpServerConfig(
          id: 'srv-2',
          name: 'Server 2',
          url: 'http://localhost:3002',
          enabled: true,
          connected: true,
          tools: [
            McpToolInfo(
              name: 'search',
              description: 'Search v2',
              inputSchema: {},
            ),
          ],
        ),
      ];

      expect(findServerForTool(servers, 'search'), 'srv-1');
    });

    test('returns null for empty server list', () {
      expect(findServerForTool([], 'search'), isNull);
    });
  });

  group('mcpToolsProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('returns empty list when no servers configured', () {
      final container = ProviderContainer(overrides: [
        effectiveSettingsProvider.overrideWithValue(
          _effective(enabledMcpServerIds: const []),
        ),
      ]);
      addTearDown(container.dispose);

      final tools = container.read(mcpToolsProvider);
      expect(tools, isEmpty);
    });

    test('returns tools from enabled and connected servers', () {
      final container = ProviderContainer(overrides: [
        effectiveSettingsProvider.overrideWithValue(
          _effective(enabledMcpServerIds: const ['srv-1']),
        ),
      ]);
      addTearDown(container.dispose);

      container.read(settingsProvider.notifier).addMcpServer(
            const McpServerConfig(
              id: 'srv-1',
              name: 'Test',
              url: 'http://localhost:3000',
              enabled: true,
              connected: true,
              tools: [
                McpToolInfo(
                  name: 'search',
                  description: 'Search',
                  inputSchema: {'type': 'object'},
                ),
              ],
            ),
          );

      final tools = container.read(mcpToolsProvider);
      expect(tools.length, 1);
      expect(tools.first['function']['name'], 'search');
    });

    test('excludes tools from servers not enabled for the conversation', () {
      final container = ProviderContainer(overrides: [
        effectiveSettingsProvider.overrideWithValue(
          _effective(enabledMcpServerIds: const []),
        ),
      ]);
      addTearDown(container.dispose);

      container.read(settingsProvider.notifier).addMcpServer(
            const McpServerConfig(
              id: 'srv-1',
              name: 'Test',
              url: 'http://localhost:3000',
              enabled: true,
              connected: true,
              tools: [
                McpToolInfo(
                  name: 'search',
                  description: 'Search',
                  inputSchema: {},
                ),
              ],
            ),
          );

      final tools = container.read(mcpToolsProvider);
      expect(tools, isEmpty);
    });

    test('excludes tools from disconnected servers', () {
      final container = ProviderContainer(overrides: [
        effectiveSettingsProvider.overrideWithValue(
          _effective(enabledMcpServerIds: const ['srv-1']),
        ),
      ]);
      addTearDown(container.dispose);

      container.read(settingsProvider.notifier).addMcpServer(
            const McpServerConfig(
              id: 'srv-1',
              name: 'Disconnected',
              url: 'http://localhost:3000',
              enabled: true,
              connected: false,
              tools: [
                McpToolInfo(
                  name: 'search',
                  description: 'Search',
                  inputSchema: {},
                ),
              ],
            ),
          );

      final tools = container.read(mcpToolsProvider);
      expect(tools, isEmpty);
    });
  });
}
