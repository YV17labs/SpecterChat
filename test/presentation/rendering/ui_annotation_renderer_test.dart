import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/annotation.dart';
import 'package:specterchat/presentation/rendering/ui_annotation_renderer.dart';

import '../../support/image_fixtures.dart';

void main() {
  const rect = AnnotationShape.rectangle(
    rect: NRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
    color: AnnotationColor.red,
    width: StrokeWidth.thick,
  );

  testWidgets('render keeps the size and strokes in colour', (tester) async {
    await tester.runAsync(() async {
      final original = await pngFixture(200, 100);
      final out = (await const UiAnnotationRenderer().render(
        original,
        const Annotation(shapes: [rect]),
      )).annotated;
      expect(await pngSize(out), (200, 100));
      // Untouched pixel far from the outline: still grey.
      expect(await pngPixel(out, 10, 10), [128, 128, 128]);
      // On the left edge of the rectangle (x = 50): red.
      final onEdge = await pngPixel(out, 50, 50);
      expect(onEdge[0], greaterThan(200));
      expect(onEdge[1], lessThan(80));
      // Inside the rectangle, away from the edge: untouched (outline only).
      expect(await pngPixel(out, 100, 50), [128, 128, 128]);
    });
  });

  testWidgets('mask strokes never appear on the annotated image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final original = await pngFixture(64, 64);
      final out = await const UiAnnotationRenderer().render(
        original,
        const Annotation(
          shapes: [
            AnnotationShape.mask(points: [NPoint(0.5, 0.5), NPoint(0.6, 0.5)]),
          ],
        ),
      );
      expect(await pngPixel(out.annotated, 32, 32), [128, 128, 128]);
      // No mask asked for, none produced.
      expect(out.mask, isNull);
    });
  });

  testWidgets('renderMask fills outlines and paints brush strokes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final original = await pngFixture(200, 100);
      final mask = (await const UiAnnotationRenderer().render(
        original,
        const Annotation(
          shapes: [
            rect,
            AnnotationShape.mask(
              points: [NPoint(0.05, 0.9), NPoint(0.15, 0.9)],
            ),
          ],
        ),
        includeMask: true,
      )).mask!;
      expect(await pngSize(mask), (200, 100));
      expect(await pngPixel(mask, 100, 50), [255, 255, 255]); // inside rect
      expect(await pngPixel(mask, 10, 10), [0, 0, 0]); // background
      expect(await pngPixel(mask, 20, 90), [255, 255, 255]); // brush stroke
    });
  });

  testWidgets('a freehand outline is closed and filled on the mask', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final mask = await UiAnnotationRenderer.renderMask(
        const Annotation(
          shapes: [
            AnnotationShape.freehand(
              points: [
                NPoint(0.2, 0.2),
                NPoint(0.8, 0.2),
                NPoint(0.8, 0.8),
                NPoint(0.2, 0.8),
              ],
              color: AnnotationColor.green,
            ),
          ],
        ),
        100,
        100,
      );
      expect(await pngPixel(mask, 50, 50), [255, 255, 255]);
      expect(await pngPixel(mask, 5, 5), [0, 0, 0]);
    });
  });
}
