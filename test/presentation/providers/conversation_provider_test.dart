import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/conversation_settings.dart';
import 'package:specterchat/presentation/providers/chat_input_provider.dart';
import 'package:specterchat/presentation/providers/conversation_provider.dart';
import 'package:specterchat/presentation/providers/conversation_settings_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';

import '../../support/pump_app.dart';

void main() {
  late TestHarness harness;

  setUp(() => harness = TestHarness());

  ProviderContainer container() {
    final c = ProviderContainer(overrides: harness.overrides);
    addTearDown(c.dispose);
    return c;
  }

  /// The list stream must have delivered once before by-id lookups work.
  Future<void> primeList(ProviderContainer c) async {
    c.listen(conversationListProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
  }

  group('ConversationController', () {
    test('createNew creates with the default prompt and selects it', () async {
      final c = container();
      c.read(settingsProvider.notifier).updateDefaultSystemPrompt('P');
      await c.read(conversationControllerProvider.notifier).createNew();
      final id = c.read(conversationControllerProvider);
      expect(id, isNotNull);
      expect(harness.conversations.rows[id]!.systemPrompt, 'P');
    });

    test('fork selects the copy and injects the draft', () async {
      final c = container();
      final source = await harness.conversations.createConversation(
        systemPrompt: 'S',
      );
      await c
          .read(conversationControllerProvider.notifier)
          .fork(source, draft: 'retry this');
      final id = c.read(conversationControllerProvider);
      expect(id, isNot(source));
      expect(harness.conversations.rows[id]!.systemPrompt, 'S');
      expect(c.read(chatInputInjectionProvider), 'retry this');
    });

    test(
      'delete deselects when the deleted conversation was selected',
      () async {
        final c = container();
        final id = await harness.conversations.createConversation();
        final controller = c.read(conversationControllerProvider.notifier);
        controller.select(id);
        await controller.delete(id);
        expect(c.read(conversationControllerProvider), isNull);
        expect(harness.conversations.rows, isEmpty);
      },
    );
  });

  group('selectedConversationProvider', () {
    test('resolves the selected id against the list', () async {
      final c = container();
      final id = await harness.conversations.createConversation();
      await primeList(c);
      c.read(conversationControllerProvider.notifier).select(id);
      expect(c.read(selectedConversationProvider)?.id, id);
      expect(c.read(conversationByIdProvider('nope')), isNull);
    });
  });

  group('MessageWindowNotifier', () {
    test('expands up to the cap', () {
      final c = container();
      c.listen(messageWindowSizeProvider('x'), (_, _) {});
      expect(c.read(messageWindowSizeProvider('x')), kDefaultMessageWindowSize);
      c
          .read(messageWindowSizeProvider('x').notifier)
          .expand(step: kMaxMessageWindowSize);
      expect(c.read(messageWindowSizeProvider('x')), kMaxMessageWindowSize);
    });
  });

  group('ConversationSettingsNotifier', () {
    test(
      'reflects edits immediately and hands the write to the actions',
      () async {
        final c = container();
        final id = await harness.conversations.createConversation(
          settings: const ConversationSettings(systemPrompt: 'keep me'),
        );
        await primeList(c);
        final provider = conversationSettingsProvider(id);
        c.listen(provider, (_, _) {});
        final n = c.read(provider.notifier);

        n.update((s) => s.copyWith(contextLength: 10));
        n.update((s) => s.copyWith(contextLength: 20));
        // Starts from the persisted settings; visible before the write lands.
        expect(
          c.read(provider),
          const ConversationSettings(
            systemPrompt: 'keep me',
            contextLength: 20,
          ),
        );
        expect(harness.conversations.rows[id]!.settings!.contextLength, isNull);

        await c.read(conversationActionsProvider).flushPendingSettings();
        expect(harness.conversations.rows[id]!.settings!.contextLength, 20);
      },
    );
  });
}
