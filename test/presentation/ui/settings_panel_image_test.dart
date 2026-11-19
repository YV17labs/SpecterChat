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
  defaults: ImageDefaults(steps: 20, guidance: 1.0),
);

const _imageModel = ModelInfo(id: 'qwen-image-2.1', image: _torch);
const _textModel = ModelInfo(id: 'llama');

/// A generation-only server: no editing, no RGBA.
const _limited = ImageModelInfo(backend: 'other', device: 'cuda');
const _limitedModel = ModelInfo(id: 'limited', image: _limited);

/// Pictor serving Turbo: a fixed schedule, the authors' settings.
const _turbo = ImageModelInfo(
  capabilities: ImageCapabilities(referenceEdit: true, fixedSteps: 8),
  defaults: ImageDefaults(steps: 8, guidance: 1.0, baseSize: 2048),
  recommended: ImageRecommendations(steps: 8, guidance: 1.0, baseSize: 2048),
);
const _turboModel = ModelInfo(id: 'turbo', image: _turbo);

/// Pictor serving the base model: 40 steps recommended, 20 by default.
const _base = ImageModelInfo(
  defaults: ImageDefaults(steps: 20, guidance: 1.0),
  recommended: ImageRecommendations(steps: 40, guidance: 1.0, baseSize: 2048),
);
const _baseModel = ModelInfo(id: 'base', image: _base);

/// An Images API model (mlx-serve): no default given, no chat.
const _imagesApi = ImageModelInfo(
  api: ImageApi.imagesEndpoint,
  capabilities: ImageCapabilities(referenceEdit: true, rgba: true),
);
const _imagesApiModel = ModelInfo(id: 'qwen-mlx', image: _imagesApi);

Future<TestHarness> _pump(
  WidgetTester tester, {
  required String selected,
  List<ModelInfo> models = const [
    _imageModel,
    _textModel,
    _limitedModel,
    _imagesApiModel,
    _turboModel,
    _baseModel,
  ],
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

  testWidgets('Images API model: no Chat, unknown defaults left empty', (
    tester,
  ) async {
    final harness = await _pump(tester, selected: 'qwen-mlx');
    final seg = tester.widget<SegmentedButton<ImageMode>>(
      find.byType(SegmentedButton<ImageMode>),
    );
    bool enabled(ImageMode m) =>
        seg.segments.singleWhere((s) => s.value == m).enabled;
    expect(enabled(ImageMode.chat), isFalse);
    expect(enabled(ImageMode.edit), isTrue);
    expect(_transparentSwitch(tester).onChanged, isNotNull);

    // No slider pretends to know the model's default: two empty fields.
    expect(find.byType(Slider), findsNothing);
    final defaults = find.widgetWithText(TextField, 'server default');
    expect(defaults, findsNWidgets(2));

    // A value equal to nothing the server said is a real override;
    // emptied, it is the server's again.
    await tester.enterText(defaults.first, '8');
    await tester.pump(const Duration(milliseconds: 600));
    expect(harness.settingsStore.stored!.image.steps, 8);
    await tester.enterText(defaults.first, '');
    await tester.pump(const Duration(milliseconds: 600));
    expect(harness.settingsStore.stored!.image.steps, isNull);

    // The range is the server's to enforce, not the panel's to guess: a
    // distilled model takes a guidance of 0, and 500 steps is refused by
    // the server, by name. A decimal comma is a decimal point.
    await tester.enterText(defaults.first, '500');
    await tester.enterText(defaults.last, '0');
    await tester.pump(const Duration(milliseconds: 600));
    expect(harness.settingsStore.stored!.image.steps, 500);
    expect(harness.settingsStore.stored!.image.guidance, 0);
    await tester.enterText(defaults.last, '3,5');
    await tester.pump(const Duration(milliseconds: 600));
    expect(harness.settingsStore.stored!.image.guidance, 3.5);
  });

  testWidgets('text that is no value says so, and never stays', (tester) async {
    const refused = 'Not a value this takes: not sent';
    final harness = await _pump(tester, selected: 'qwen-mlx');
    final steps = find.widgetWithText(TextField, 'server default').first;
    String shown() => tester.widget<TextField>(steps).controller!.text;

    await tester.enterText(steps, '8');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(refused), findsNothing);

    // "0" is no step count: the field says so and nothing changes…
    await tester.enterText(steps, '0');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(refused), findsOneWidget);
    expect(harness.settingsStore.stored!.image.steps, 8);

    // …and once left, the field shows what is actually set.
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    expect(find.text(refused), findsNothing);
    expect(shown(), '8');

    // The same with nothing set: the text goes, it does not pass for a
    // value that Reset or a conversation switch then fails to clear.
    await tester.enterText(steps, '');
    await tester.enterText(steps, 'many');
    await tester.pump(const Duration(milliseconds: 600));
    expect(harness.settingsStore.stored!.image.steps, isNull);
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    expect(shown(), isEmpty);
  });

  testWidgets('the dice sets a seed and the field shows it', (tester) async {
    final harness = await _pump(tester, selected: 'qwen-mlx');
    final seedField = find.widgetWithText(TextField, 'random');
    await tester.enterText(seedField, '42');
    await tester.pump(const Duration(milliseconds: 600));
    expect(harness.settingsStore.stored!.image.seed, 42);

    // Pressed while the field still holds the focus and another value.
    await tester.tap(find.byIcon(Icons.casino_outlined));
    await tester.pump(const Duration(milliseconds: 600));
    final seed = harness.settingsStore.stored!.image.seed;
    expect(seed, isNotNull);
    expect(tester.widget<TextField>(seedField).controller!.text, '$seed');
  });

  testWidgets('a fixed schedule replaces the Steps control', (tester) async {
    await _pump(tester, selected: 'turbo');
    expect(find.text('8, fixed by this model'), findsOneWidget);
    // Guidance is still a slider; there is no Steps one.
    expect(find.byType(Slider), findsOneWidget);
    expect(find.textContaining('Steps ·'), findsNothing);
  });

  testWidgets("the authors' settings are marked next to the controls", (
    tester,
  ) async {
    await _pump(tester, selected: 'base');
    expect(find.text('Steps · 40 recommended'), findsOneWidget);
    expect(find.text('Guidance · 1.0 recommended'), findsOneWidget);
    // The recommended size is offered even when it is not the default.
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(
      find.text('2048 px (≈4.2 MP) · recommended').hitTestable(),
      findsOneWidget,
    );
    expect(
      find.text('1024 px (≈1.0 MP) · default').hitTestable(),
      findsOneWidget,
    );
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
