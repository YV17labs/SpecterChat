import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/annotation_geometry.dart';
import 'package:specterchat/application/images/annotation_history.dart';
import 'package:specterchat/domain/models/annotation.dart';

void main() {
  const a = AnnotationShape.freehand(
    points: [NPoint(0.1, 0.1), NPoint(0.2, 0.1)],
    color: AnnotationColor.red,
  );
  const b = AnnotationShape.rectangle(
    rect: NRect(left: 0.5, top: 0.5, right: 0.9, bottom: 0.9),
    color: AnnotationColor.blue,
  );

  group('AnnotationHistory', () {
    test('push / undo / redo walk the timeline', () {
      var h = const AnnotationHistory.initial();
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);

      h = h.push(h.present.add(a));
      h = h.push(h.present.add(b));
      expect(h.present.shapes, [a, b]);
      expect(h.canUndo, isTrue);

      h = h.undo();
      expect(h.present.shapes, [a]);
      expect(h.canRedo, isTrue);

      h = h.redo();
      expect(h.present.shapes, [a, b]);
      expect(h.canRedo, isFalse);

      h = h.undo().undo();
      expect(h.present, Annotation.empty);
      expect(h.undo().present, Annotation.empty); // no-op at the start
    });

    test('a new push after undo drops the redo branch', () {
      var h = const AnnotationHistory.initial();
      h = h.push(h.present.add(a)).undo();
      h = h.push(h.present.add(b));
      expect(h.canRedo, isFalse);
      expect(h.present.shapes, [b]);
    });

    test('pushing an identical state is a no-op', () {
      var h = const AnnotationHistory.initial();
      h = h.push(Annotation.empty);
      expect(h.canUndo, isFalse);
      expect(identical(h, h.push(h.present)), isTrue);
    });

    test('history depth is bounded', () {
      var h = const AnnotationHistory.initial();
      for (var i = 0; i < AnnotationHistory.maxDepth + 20; i++) {
        h = h.push(h.present.add(a));
      }
      var undos = 0;
      while (h.canUndo) {
        h = h.undo();
        undos++;
      }
      expect(undos, AnnotationHistory.maxDepth);
    });
  });

  group('AnnotationGeometry.hitTest', () {
    const geo = AnnotationGeometry(aspectRatio: 2); // 2:1 landscape
    const doc = Annotation(
      shapes: [
        a,
        b,
        AnnotationShape.ellipse(
          rect: NRect(left: 0.1, top: 0.6, right: 0.3, bottom: 0.9),
          color: AnnotationColor.green,
        ),
      ],
    );

    test('finds the polyline, rectangle edge and ellipse outline', () {
      expect(geo.hitTest(doc, const NPoint(0.15, 0.105)), 0);
      expect(geo.hitTest(doc, const NPoint(0.7, 0.505)), 1); // top edge
      // Right-most point of the ellipse: centre (0.2, 0.75), rx = 0.1.
      expect(geo.hitTest(doc, const NPoint(0.3, 0.75)), 2);
      // Inside the rectangle but far from any edge → nothing.
      expect(geo.hitTest(doc, const NPoint(0.7, 0.7)), isNull);
    });

    test('respects the aspect ratio when measuring distances', () {
      // Horizontal gap of 0.05 in normalised x is 0.1 in unit-height space
      // on a 2:1 image, so a 0.06 tolerance must miss it.
      expect(
        geo.hitTest(doc, const NPoint(0.25, 0.1), tolerance: 0.06),
        isNull,
      );
      expect(
        const AnnotationGeometry(
          aspectRatio: 1,
        ).hitTest(doc, const NPoint(0.25, 0.1), tolerance: 0.06),
        0,
      );
    });
  });
}
