import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/drawing_session.dart';
import 'package:specterchat/application/images/pending_image.dart';
import 'package:specterchat/domain/models/annotation.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/presentation/ui/chat/chat_input_area.dart';
import 'package:specterchat/presentation/ui/chat/pending_image_strip.dart';

import '../../../support/image_fixtures.dart';
import '../../../support/pump_app.dart';

void main() {
  group('PendingImageStrip', () {
    testWidgets('renders one thumbnail per image and removes on ×', (
      tester,
    ) async {
      final bytes = (await tester.runAsync(() => pngFixture(8, 8)))!;
      final removed = <String>[];
      await pumpApp(
        tester,
        PendingImageStrip(
          images: [
            PendingImage(
              id: 'a',
              name: 'a.png',
              image: DescribedImage(bytes: bytes, mimeType: 'image/png'),
            ),
            PendingImage(
              id: 'b',
              name: 'b.png',
              image: DescribedImage(bytes: bytes, mimeType: 'image/png'),
            ),
          ],
          onRemove: removed.add,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump();
      expect(removed, ['a']);
    });

    testWidgets(
      'edit button opens the editor and annotated images get a badge',
      (tester) async {
        final bytes = (await tester.runAsync(() => pngFixture(8, 8)))!;
        final edited = <String>[];
        const annotation = Annotation(
          shapes: [
            AnnotationShape.ellipse(
              rect: NRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
              color: AnnotationColor.red,
            ),
          ],
        );
        await pumpApp(
          tester,
          PendingImageStrip(
            images: [
              PendingImage(
                id: 'plain',
                name: 'plain.png',
                image: DescribedImage(bytes: bytes, mimeType: 'image/png'),
              ),
              PendingImage(
                id: 'drawn',
                name: 'drawn.png',
                image: DescribedImage(bytes: bytes, mimeType: 'image/png'),
                annotation: const AnnotationResult(
                  annotation: annotation,
                  includeMask: true,
                  keepOriginal: false,
                ),
              ),
            ],
            onRemove: (_) {},
            onEdit: edited.add,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Annotate image'), findsNWidgets(2));
        expect(find.bySemanticsLabel('Annotated'), findsOneWidget);

        await tester.tap(find.bySemanticsLabel('Annotate image').last);
        await tester.pump();
        expect(edited, ['drawn']);

        // Tapping the thumbnail itself also opens the editor.
        await tester.tap(find.byType(Image).first);
        await tester.pump();
        expect(edited, ['drawn', 'plain']);
      },
    );

    testWidgets('is empty when there are no images', (tester) async {
      await pumpApp(
        tester,
        PendingImageStrip(images: const [], onRemove: (_) {}),
      );
      expect(find.byType(Image), findsNothing);
    });
  });

  group('ChatInputArea', () {
    testWidgets('shows the strip, attach button and image hint', (
      tester,
    ) async {
      final bytes = (await tester.runAsync(() => pngFixture(8, 8)))!;
      var attachTaps = 0;
      await pumpApp(
        tester,
        ChatInputArea(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          isGenerating: false,
          pendingImages: [
            PendingImage(
              id: 'a',
              name: 'a',
              image: DescribedImage(bytes: bytes, mimeType: 'image/png'),
            ),
          ],
          onSend: () {},
          onStop: () {},
          onAttach: () => attachTaps++,
          onRemoveImage: (_) {},
          onPaste: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PendingImageStrip), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(
        find.text('Describe what to do with the image...'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Attach image'));
      expect(attachTaps, 1);
    });
  });
}
