import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/presentation/providers/image_reuse_provider.dart';
import 'package:specterchat/presentation/ui/widgets/image_block.dart';

import '../../../support/image_fixtures.dart';
import '../../../support/pump_app.dart';

void main() {
  testWidgets('copy, save and annotate go through the image services', (
    tester,
  ) async {
    final png = (await tester.runAsync(() => pngFixture(16, 16)))!;
    final harness = TestHarness();
    await harness.attachments.storeBytes(
      attachmentId: 'att',
      messageId: 'm',
      bytes: png,
      mimeType: 'image/png',
    );
    // A fixed box: the block only learns its own height once the engine
    // has decoded the image, which a widget test does not wait for.
    final container = await pumpApp(
      tester,
      const SizedBox(
        width: 300,
        height: 300,
        child: ImageBlock(attachmentId: 'att', mimeType: 'image/png'),
      ),
      harness: harness,
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    // Reveal the overlay.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(Image)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Copy image'));
    await tester.pumpAndSettle();
    expect(harness.imageIo.copied.single, png);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.byTooltip('Save as…'));
    await tester.pumpAndSettle();
    expect(harness.imageIo.saved.single.mimeType, 'image/png');
    expect(harness.imageIo.saved.single.bytes, png);

    await tester.tap(find.byTooltip('Annotate & reuse'));
    await tester.pump();
    final request = container.read(imageReuseProvider);
    expect(request?.bytes, png);
    expect(request?.mimeType, 'image/png');
  });

  testWidgets('a missing attachment shows a placeholder, no services', (
    tester,
  ) async {
    await pumpApp(
      tester,
      const ImageBlock(attachmentId: 'nope', mimeType: 'image/png'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Image unavailable'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
