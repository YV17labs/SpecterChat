import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';

import '../../support/fakes.dart';

void main() {
  late InMemorySettingsStore store;

  setUp(() => store = InMemorySettingsStore());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('starts with defaults, then adopts what the store holds', () async {
    store.stored = const AppSettings(defaultSystemPrompt: 'from disk');
    final c = container();
    expect(c.read(settingsProvider), const AppSettings());
    await Future<void>.delayed(Duration.zero);
    expect(c.read(settingsProvider).defaultSystemPrompt, 'from disk');
  });

  test('stays on defaults when the store is empty', () async {
    final c = container();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(settingsProvider), const AppSettings());
  });

  test('updateApi / updateGeneration / updateDefaultSystemPrompt', () {
    final c = container();
    final n = c.read(settingsProvider.notifier);
    n.updateApi(const ApiSettings(apiKey: 'sk-new', selectedModel: 'gpt-4'));
    n.updateGeneration(const GenerationSettings(temperature: 0.3));
    n.updateDefaultSystemPrompt('You are helpful');
    final s = c.read(settingsProvider);
    expect(s.api.apiKey, 'sk-new');
    expect(s.api.selectedModel, 'gpt-4');
    expect(s.generation.temperature, 0.3);
    expect(s.defaultSystemPrompt, 'You are helpful');
  });

  test('MCP server list edits', () {
    final c = container();
    final n = c.read(settingsProvider.notifier);
    const a = McpServerConfig(id: 'a', name: 'A', url: 'http://a');
    const b = McpServerConfig(id: 'b', name: 'B', url: 'http://b');

    n.replaceMcpServers([a, b]);
    expect(c.read(settingsProvider).mcpServers, [a, b]);

    n.removeMcpServer('a');
    expect(c.read(settingsProvider).mcpServers, [b]);
  });

  test('changes are saved once after the debounce window', () async {
    final c = container();
    final n = c.read(settingsProvider.notifier);
    n.updateDefaultSystemPrompt('a');
    n.updateDefaultSystemPrompt('ab');
    n.updateDefaultSystemPrompt('abc');
    expect(store.saves, 0);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(store.saves, 1);
    expect(store.stored!.defaultSystemPrompt, 'abc');
  });
}
