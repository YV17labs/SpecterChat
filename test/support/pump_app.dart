import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/core/theme.dart';
import 'package:specterchat/presentation/providers/database_provider.dart';
import 'package:specterchat/presentation/providers/llm_provider.dart';
import 'package:specterchat/presentation/providers/mcp_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';

import 'fakes.dart';

/// Everything a widget test needs to run the real provider graph on top of
/// in-memory fakes.
class TestHarness {
  final conversations = InMemoryConversationRepository();
  final messages = InMemoryMessageRepository();
  final attachments = InMemoryAttachmentRepository();
  final settingsStore = InMemorySettingsStore();
  final mcp = FakeMcpService();
  FakeLlmService llm;

  TestHarness({FakeLlmService? llm}) : llm = llm ?? FakeLlmService([]);

  List<Override> get overrides => [
    conversationRepositoryProvider.overrideWithValue(conversations),
    messageRepositoryProvider.overrideWithValue(messages),
    attachmentRepositoryProvider.overrideWithValue(attachments),
    settingsStoreProvider.overrideWithValue(settingsStore),
    mcpServiceProvider.overrideWithValue(mcp),
    llmServiceProvider.overrideWith((_) => llm),
  ];
}

/// Pumps [child] inside a themed [MaterialApp] and a [ProviderScope]
/// wired to [harness]. Returns the container for reads/writes.
Future<ProviderContainer> pumpApp(
  WidgetTester tester,
  Widget child, {
  TestHarness? harness,
  Size size = const Size(1400, 900),
}) async {
  final h = harness ?? TestHarness();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  late final ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides,
      child: Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
            theme: SpecterTheme.darkTheme,
            home: Scaffold(body: child),
          );
        },
      ),
    ),
  );
  return container;
}
