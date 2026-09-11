import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/conversation.dart';
import 'package:specterchat/domain/models/conversation_settings.dart';
import 'package:specterchat/domain/models/effective_settings.dart';

void main() {
  const global = AppSettings(
    api: ApiSettings(contextLength: 1000),
    generation: GenerationSettings(temperature: 0.2),
    defaultSystemPrompt: 'global prompt',
  );

  Conversation conv({String? prompt, ConversationSettings? settings}) =>
      Conversation(
        id: 'c',
        title: 't',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
        systemPrompt: prompt,
        settings: settings,
      );

  test('global() mirrors the app settings with no conversation', () {
    final e = EffectiveSettings.global(global);
    expect(e.systemPrompt, 'global prompt');
    expect(e.contextLength, 1000);
    expect(e.generation.temperature, 0.2);
    expect(e.enabledMcpServerIds, isEmpty);
  });

  test('resolve() falls back through override → conversation → global', () {
    final none = EffectiveSettings.resolve(global, conv());
    expect(none.systemPrompt, 'global prompt');

    final convPrompt = EffectiveSettings.resolve(global, conv(prompt: 'conv'));
    expect(convPrompt.systemPrompt, 'conv');

    final overridden = EffectiveSettings.resolve(
      global,
      conv(
        prompt: 'conv',
        settings: const ConversationSettings(
          systemPrompt: 'override',
          contextLength: 42,
          generation: GenerationSettings(temperature: 1.5),
          enabledMcpServerIds: ['srv'],
        ),
      ),
    );
    expect(overridden.systemPrompt, 'override');
    expect(overridden.contextLength, 42);
    expect(overridden.generation.temperature, 1.5);
    expect(overridden.enabledMcpServerIds, ['srv']);
  });

  test('value equality', () {
    expect(EffectiveSettings.global(global), EffectiveSettings.global(global));
  });
}
