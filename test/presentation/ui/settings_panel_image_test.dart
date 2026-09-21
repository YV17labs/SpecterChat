import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/presentation/providers/conversation_provider.dart';
import 'package:specterchat/presentation/providers/model_catalog_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';
import 'package:specterchat/presentation/ui/sidebar_right/image_settings_section.dart';
import 'package:specterchat/presentation/ui/sidebar_right/settings_panel.dart';

import '../../support/pump_app.dart';

/// The native server: instruction editing and transparency.
const _torch = ImageModelInfo(
  backend: 'torch',
  device: 'mps',
  capabilities: ImageCapabilities(
    referenceEdit: true,
    maxReferenceImages: 10,
    rgba: true,
  ),
);

const _imageModel = ModelInfo(id: 'qwen-image-2.1', image: _torch);
const _textModel = ModelInfo(id: 'llama');

/// A generation-only server: no editing, no RGBA.
const _limited = ImageModelInfo(backend: 'other', device: 'cuda');
const _limitedModel = ModelInfo(id: 'limited', image: _limited);

Future<TestHarness> _pump(
  WidgetTester tester, {
  required String selected,
  List<ModelInfo> models = const [_imageModel, _textModel, _limitedModel],
  Map<String, ImageModelInfo> cachedImageModels = const {},
}) async {
  final harness = TestHarness();
  harness.llm.models = models;
  harness.modelCatalogStore.stored = cachedImageModels;
  harness.settingsStore.stored = AppSettings(
    api: ApiSettings(selectedModel: selected),
  );
  // Tall surface so the whole (lazy) ListView is built: the assertions
  // below look for headers near the bottom of the panel.
  await pumpApp(
    tester,
    const SizedBox(width: 320, child: SettingsPanel()),
    harness: harness,
    size: const Size(1400, 2400),
  );
  await tester.pumpAndSettle();
  return harness;
}

Switch _transparentSwitch(WidgetTester tester) => tester.widget<Switch>(
  find.descendant(
    of: find.ancestor(
      of: find.text('Transparent background'),
      matching: find.byType(Row),
    ),
    matching: find.byType(Switch),
  ),
);

void main() {
  testWidgets('image model: Image section replaces the text-LLM sections', (
    tester,
  ) async {
    await _pump(tester, selected: 'qwen-image-2.1');

    expect(find.text('Image'), findsOneWidget);
    expect(find.byType(ImageSettingsSection), findsOneWidget);
    expect(find.text('Generation'), findsNothing);
    expect(find.text('Temperature'), findsNothing);
    expect(find.text('Context Length'), findsNothing);
    expect(find.text('System Prompt'), findsNothing);
    expect(find.text('MCP Servers'), findsNothing);
    expect(find.text('API Connection'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    // No capabilities caption under the title (removed on request).
    expect(find.textContaining('instruction editing'), findsNothing);
    // The controls that stay.
    for (final label in [
      'Mode',
      'Aspect ratio',
      'Size',
      'Steps',
      'Seed',
      'Guidance',
      'Negative prompt',
      'Transparent background',
      'Reset',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(_transparentSwitch(tester).onChanged, isNotNull);
    // The controls that are gone with the single native backend.
    expect(find.text('Edit method'), findsNothing);
    expect(find.text('Backend'), findsNothing);
    expect(find.text('Img2img strength'), findsNothing);
    expect(find.text('Prompt rewriting'), findsNothing);
  });

  testWidgets('generation-only server: Edit disabled, transparency disabled', (
    tester,
  ) async {
    await _pump(tester, selected: 'limited');
    final seg = tester.widget<SegmentedButton<ImageMode>>(
      find.byType(SegmentedButton<ImageMode>),
    );
    final edit = seg.segments.singleWhere((s) => s.value == ImageMode.edit);
    expect(edit.enabled, isFalse);
    expect(_transparentSwitch(tester).onChanged, isNull);
  });

  testWidgets("text model: today's panel, no Image section", (tester) async {
    await _pump(tester, selected: 'llama');

    expect(find.byType(ImageSettingsSection), findsNothing);
    expect(find.text('Generation'), findsOneWidget);
    expect(find.text('Context Length'), findsOneWidget);
    expect(find.text('System Prompt'), findsOneWidget);
    expect(find.text('MCP Servers'), findsOneWidget);
  });

  testWidgets('image edits go to the conversation override, reset clears', (
    tester,
  ) async {
    final harness = await _pump(tester, selected: 'qwen-image-2.1');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPanel)),
    );
    final id = await harness.conversations.createConversation();
    container.read(conversationControllerProvider.notifier).select(id);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Generate'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'random'), '42');
    await tester.pump(const Duration(milliseconds: 600));

    final stored = harness.conversations.rows[id]!.settings!.image!;
    expect(stored.mode, ImageMode.generate);
    expect(stored.seed, 42);
    expect(container.read(settingsProvider).image, const ImageSettings());

    await tester.tap(find.text('Reset'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      harness.conversations.rows[id]!.settings!.image,
      const ImageSettings(),
    );
  });

  testWidgets('known image models survive without a fetch', (tester) async {
    await _pump(
      tester,
      selected: 'qwen-image-2.1',
      models: const [_textModel], // server no longer lists it…
      cachedImageModels: const {'qwen-image-2.1': _torch},
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPanel)),
    );
    // …but the persisted description still drives the panel: the id is
    // simply absent from the new list, so it is kept.
    expect(container.read<ImageModelInfo?>(selectedImageModelProvider), _torch);
    expect(find.byType(ImageSettingsSection), findsOneWidget);
  });

  testWidgets('a model the server now lists as text drops out', (tester) async {
    final harness = await _pump(
      tester,
      selected: 'qwen-image-2.1',
      models: const [ModelInfo(id: 'qwen-image-2.1')],
      cachedImageModels: const {'qwen-image-2.1': _torch},
    );
    expect(find.byType(ImageSettingsSection), findsNothing);
    expect(find.text('Generation'), findsOneWidget);
    expect(harness.modelCatalogStore.stored, isEmpty);
  });
}
