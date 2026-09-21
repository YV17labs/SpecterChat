import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/pending_image.dart';
import 'package:specterchat/domain/models/annotation.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/presentation/providers/composer_provider.dart';
import 'package:specterchat/presentation/providers/conversation_provider.dart';
import 'package:specterchat/presentation/providers/image_reuse_provider.dart';
import 'package:specterchat/presentation/ui/chat/annotation/annotation_editor.dart';
import 'package:specterchat/presentation/ui/chat/chat_view.dart';
import 'package:specterchat/presentation/ui/chat/pending_image_strip.dart';

import '../../../support/fakes.dart';
import '../../../support/image_fixtures.dart';
import '../../../support/pump_app.dart';

/// The composer inside a [ChatView] with one conversation selected. The
/// harness uses a pass-through normaliser and a fake renderer, so no real
/// engine decode happens and `pumpAndSettle` does not stall.
Future<(TestHarness, ProviderContainer, String)> _pump(
  WidgetTester tester, {
  List<List<StreamEvent>> turns = const [],
}) async {
  final harness = TestHarness(llm: FakeLlmService.events(turns));
  final container = await pumpApp(tester, const ChatView(), harness: harness);
  final id = await harness.conversations.createConversation();
  container.read(conversationControllerProvider.notifier).select(id);
  await tester.pumpAndSettle();
  return (harness, container, id);
}

Future<void> _pressPaste(WidgetTester tester) async {
  await tester.tap(find.byType(TextField));
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the attach button queues what the dialog returned', (
    tester,
  ) async {
    final (harness, container, id) = await _pump(tester);
    harness.imageIo.picked = [
      FakeImageIo.pickedFile('cat.png', fakePngBytes(1)),
      FakeImageIo.pickedFile('notes.txt', Uint8List.fromList([1, 2])),
      FakeImageIo.pickedFile('dog.png', fakePngBytes(2)),
    ];
    await tester.tap(find.byTooltip('Attach image'));
    await tester.pumpAndSettle();

    final pending = container.read(composerProvider(id));
    expect(pending.map((i) => i.name), ['cat.png', 'dog.png']);
    expect(find.text('Not an image: notes.txt'), findsOneWidget);
    expect(find.byType(PendingImageStrip), findsOneWidget);
    expect(find.text('Describe what to do with the image...'), findsOneWidget);
  });

  testWidgets('Cmd+V attaches a clipboard image, else pastes text', (
    tester,
  ) async {
    final (harness, container, id) = await _pump(tester);
    harness.imageIo.clipboardImage = fakePngBytes();
    await _pressPaste(tester);
    expect(container.read(composerProvider(id)), hasLength(1));
    expect(container.read(composerProvider(id)).single.name, 'Pasted image');

    harness.imageIo.clipboardImage = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': 'pasted!'} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pressPaste(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'pasted!',
    );
    expect(container.read(composerProvider(id)), hasLength(1));
  });

  testWidgets('unsupported clipboard bytes are refused with a message', (
    tester,
  ) async {
    final (harness, container, id) = await _pump(tester);
    harness.imageIo.clipboardImage = Uint8List.fromList([1, 2, 3]);
    await _pressPaste(tester);
    expect(container.read(composerProvider(id)), isEmpty);
    expect(find.text('Not an image: Pasted image'), findsOneWidget);
  });

  testWidgets('the cap is enforced with a message', (tester) async {
    final (harness, container, id) = await _pump(tester);
    harness.imageIo.picked = [
      for (var i = 0; i <= kMaxPendingImages; i++)
        FakeImageIo.pickedFile('$i.png', fakePngBytes(i)),
    ];
    await tester.tap(find.byTooltip('Attach image'));
    await tester.pumpAndSettle();
    expect(container.read(composerProvider(id)), hasLength(kMaxPendingImages));
    expect(
      find.text('At most $kMaxPendingImages images per message'),
      findsOneWidget,
    );
  });

  testWidgets('sending expands annotations and clears the composer', (
    tester,
  ) async {
    final (harness, container, id) = await _pump(
      tester,
      turns: [
        [const ContentDelta('seen'), const StreamDone()],
      ],
    );
    harness.imageIo.clipboardImage = fakePngBytes(7);
    await _pressPaste(tester);
    await tester.enterText(find.byType(TextField), 'what is this');
    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pumpAndSettle();

    expect(container.read(composerProvider(id)), isEmpty);
    final user = harness.messages.messagesFor(id).first;
    expect(user.role, MessageRole.user);
    expect(user.plainText, 'what is this');
    final image = user.content.whereType<ImageContentBlock>().single;
    expect(
      harness.attachments.rows[image.attachmentId]?.bytes,
      fakePngBytes(7),
    );
    // No annotation: the renderer was never involved.
    expect(harness.annotationRenderer.rendered, isEmpty);
  });

  testWidgets('an image-only message can be sent', (tester) async {
    final (harness, _, id) = await _pump(
      tester,
      turns: [
        [const ContentDelta('a cat'), const StreamDone()],
      ],
    );
    harness.imageIo.clipboardImage = fakePngBytes();
    await _pressPaste(tester);
    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pumpAndSettle();
    final user = harness.messages.messagesFor(id).first;
    expect(user.content.whereType<TextContentBlock>(), isEmpty);
    expect(user.content.whereType<ImageContentBlock>(), hasLength(1));
  });

  testWidgets('a rendering failure restores the draft', (tester) async {
    final (harness, container, id) = await _pump(tester);
    harness.imageIo.clipboardImage = fakePngBytes();
    await _pressPaste(tester);
    // Annotate through the notifier: the editor needs a decodable image.
    final pendingId = container.read(composerProvider(id)).single.id;
    container
        .read(composerProvider(id).notifier)
        .applyAnnotation(
          pendingId,
          const AnnotationResult(
            annotation: Annotation(
              shapes: [
                AnnotationShape.mask(points: [NPoint(0.5, 0.5)]),
              ],
            ),
            includeMask: true,
            keepOriginal: false,
          ),
        );
    harness.annotationRenderer.failWith = Exception('gpu');
    await tester.enterText(find.byType(TextField), 'edit this');
    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pumpAndSettle();

    expect(harness.messages.rows, isEmpty);
    expect(container.read(composerProvider(id)).single.id, pendingId);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'edit this',
    );
    expect(find.text('Could not render the annotated image'), findsOneWidget);
  });

  testWidgets('an annotated image sends copy + mask, in order', (tester) async {
    final (harness, container, id) = await _pump(
      tester,
      turns: [
        [const ContentDelta('done'), const StreamDone()],
      ],
    );
    harness.imageIo.clipboardImage = fakePngBytes(3);
    await _pressPaste(tester);
    final pendingId = container.read(composerProvider(id)).single.id;
    container
        .read(composerProvider(id).notifier)
        .applyAnnotation(
          pendingId,
          const AnnotationResult(
            annotation: Annotation(
              shapes: [
                AnnotationShape.rectangle(
                  rect: NRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
                  color: AnnotationColor.red,
                ),
              ],
            ),
            includeMask: true,
            keepOriginal: true,
          ),
        );
    await tester.pump();
    expect(find.bySemanticsLabel('Annotated'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'In the red area: a hat');
    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pumpAndSettle();

    final user = harness.messages.messagesFor(id).first;
    final blocks = user.content.whereType<ImageContentBlock>().toList();
    expect(blocks, hasLength(3));
    final bytes = [
      for (final b in blocks) harness.attachments.rows[b.attachmentId]!.bytes,
    ];
    expect(bytes[0].last, FakeAnnotationRenderer.annotatedMarker);
    expect(bytes[1], FakeAnnotationRenderer.maskBytes);
    expect(bytes[2], fakePngBytes(3));
  });

  testWidgets('"annotate & reuse" attaches a copy and opens the editor', (
    tester,
  ) async {
    final (harness, container, id) = await _pump(tester);
    // A real PNG so the editor can decode it.
    final png = await tester.runAsync(() => pngFixture(8, 8));
    // The editor decodes the image on the engine (real async), so the
    // request runs under `runAsync` with a real delay before pumping.
    await tester.runAsync(() async {
      container.read(imageReuseProvider.notifier).request(png!, 'image/png');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(container.read(composerProvider(id)).single.name, 'Reused image');
    expect(find.byType(AnnotationEditor), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AnnotationEditor), findsNothing);
    expect(harness.messages.rows, isEmpty);
  });

  testWidgets('removing a thumbnail drops it from the draft', (tester) async {
    final (harness, container, id) = await _pump(tester);
    harness.imageIo.clipboardImage = fakePngBytes();
    await _pressPaste(tester);
    await tester.tap(find.bySemanticsLabel('Remove image'));
    await tester.pump();
    expect(container.read(composerProvider(id)), isEmpty);
    expect(find.byType(Image), findsNothing);
  });
}
