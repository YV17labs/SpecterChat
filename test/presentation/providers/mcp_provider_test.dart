import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/effective_settings.dart';
import 'package:specterchat/domain/models/mcp_server_state.dart';
import 'package:specterchat/domain/services/i_mcp_service.dart';
import 'package:specterchat/presentation/providers/effective_settings_provider.dart';
import 'package:specterchat/presentation/providers/mcp_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';

import '../../support/fakes.dart';

class _ConnectingMcp extends FakeMcpService {
  final McpConnectResult Function(McpServerConfig) onConnect;
  _ConnectingMcp(this.onConnect);

  @override
  Future<McpConnectResult> connect(McpServerConfig config) async =>
      onConnect(config);
}

EffectiveSettings _effective(List<String> enabledIds) => EffectiveSettings(
  systemPrompt: '',
  generation: const GenerationSettings(),
  contextLength: 32768,
  enabledMcpServerIds: enabledIds,
);

const _srv = McpServerConfig(id: 'srv-1', name: 'Test', url: 'http://x');

void main() {
  ProviderContainer container({
    List<String> enabledIds = const ['srv-1'],
    IMcpService? mcp,
  }) {
    final c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        effectiveSettingsProvider.overrideWithValue(_effective(enabledIds)),
        if (mcp != null) mcpServiceProvider.overrideWithValue(mcp),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('McpConnectionController', () {
    test('connect stores what the server advertised', () async {
      final c = container(
        mcp: _ConnectingMcp(
          (_) => McpConnectResult(
            tools: [tool('search')],
            instructions: 'be nice',
          ),
        ),
      );
      await c.read(mcpServerStatesProvider.notifier).connect(_srv);
      final state = c.read(mcpServerStateProvider('srv-1'));
      expect(state.status, McpConnectionStatus.connected);
      expect(state.tools.map((t) => t.name), ['search']);
      expect(state.instructions, 'be nice');
    });

    test('a failed connect records the error and rethrows', () async {
      final c = container(
        mcp: _ConnectingMcp((_) => throw McpException('refused')),
      );
      final controller = c.read(mcpServerStatesProvider.notifier);
      await expectLater(controller.connect(_srv), throwsA(isA<McpException>()));
      final state = c.read(mcpServerStateProvider('srv-1'));
      expect(state.connected, isFalse);
      expect(state.lastError, contains('refused'));
    });

    test('disconnect and disconnectMissing drop state', () async {
      final c = container(
        mcp: _ConnectingMcp((_) => McpConnectResult(tools: const [])),
      );
      final controller = c.read(mcpServerStatesProvider.notifier);
      await controller.connect(_srv);
      await controller.connect(_srv.copyWith(id: 'srv-2'));
      controller.disconnectMissing(['srv-2']);
      expect(c.read(mcpServerStatesProvider).keys, ['srv-2']);
      controller.disconnect('srv-2');
      expect(c.read(mcpServerStatesProvider), isEmpty);
    });

    test('setToolEnabled flips one tool', () async {
      final c = container(
        mcp: _ConnectingMcp(
          (_) => McpConnectResult(tools: [tool('a'), tool('b')]),
        ),
      );
      final controller = c.read(mcpServerStatesProvider.notifier);
      await controller.connect(_srv);
      controller.setToolEnabled(
        serverId: 'srv-1',
        toolName: 'a',
        enabled: false,
      );
      final tools = c.read(mcpServerStateProvider('srv-1')).tools;
      expect(tools.map((t) => (t.name, t.enabled)), [
        ('a', false),
        ('b', true),
      ]);
    });
  });

  group('activeMcpServersProvider', () {
    test('empty when nothing is configured', () {
      expect(container().read(activeMcpServersProvider), isEmpty);
    });

    test(
      'requires configured + globally enabled + conversation-enabled + connected',
      () async {
        final c = container(
          mcp: _ConnectingMcp((_) => McpConnectResult(tools: [tool('search')])),
        );
        final settings = c.read(settingsProvider.notifier);
        final controller = c.read(mcpServerStatesProvider.notifier);

        settings.replaceMcpServers([_srv]);
        expect(
          c.read(activeMcpServersProvider),
          isEmpty,
          reason: 'not connected',
        );

        await controller.connect(_srv);
        expect(c.read(activeMcpServersProvider).map((s) => s.id), ['srv-1']);

        settings.replaceMcpServers([_srv.copyWith(enabled: false)]);
        expect(
          c.read(activeMcpServersProvider),
          isEmpty,
          reason: 'globally off',
        );
      },
    );

    test('excludes servers not enabled for the conversation', () async {
      final c = container(
        enabledIds: const [],
        mcp: _ConnectingMcp((_) => McpConnectResult(tools: [tool('search')])),
      );
      c.read(settingsProvider.notifier).replaceMcpServers([_srv]);
      await c.read(mcpServerStatesProvider.notifier).connect(_srv);
      expect(c.read(activeMcpServersProvider), isEmpty);
    });
  });
}
