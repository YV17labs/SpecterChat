import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/drawing_session.dart';
import 'package:specterchat/domain/models/annotation.dart';

void main() {
  DrawingSession fresh({
    Annotation start = Annotation.empty,
    int freeSlots = 2,
    bool includeMask = false,
    bool keepOriginal = false,
  }) => DrawingSession.initial(
    aspectRatio: 2,
    start: start,
    freeSlots: freeSlots,
    includeMask: includeMask,
    keepOriginal: keepOriginal,
  );

  group('pen', () {
    test('down → moves → up commits a freehand stroke', () {
      var s = fresh()
          .pointerDown(const NPoint(0.1, 0.1))
          .pointerMove(const NPoint(0.2, 0.2))
          .pointerMove(const NPoint(0.3, 0.3));
      expect(s.isDrawing, isTrue);
      expect(s.inProgress, isA<FreehandStroke>());
      expect(s.annotation, Annotation.empty);

      s = s.pointerUp();
      expect(s.isDrawing, isFalse);
      expect(s.inProgress, isNull);
      final stroke = s.annotation.shapes.single as FreehandStroke;
      expect(stroke.points, hasLength(3));
      expect(stroke.color, AnnotationColor.red);
      expect(stroke.width, StrokeWidth.medium);
      expect(s.canUndo, isTrue);
    });

    test('a click without a drag is a one-point stroke (a dot)', () {
      final s = fresh().pointerDown(const NPoint(0.5, 0.5)).pointerUp();
      final stroke = s.annotation.shapes.single as FreehandStroke;
      expect(stroke.points, [const NPoint(0.5, 0.5)]);
    });

    test('sub-pixel jitter is dropped', () {
      final s = fresh()
          .pointerDown(const NPoint(0.5, 0.5))
          .pointerMove(const NPoint(0.5004, 0.5004));
      expect((s.inProgress! as FreehandStroke).points, hasLength(1));
    });

    test('colour and width apply to the next stroke', () {
      final s = fresh()
          .selectColor(AnnotationColor.blue)
          .selectWidth(StrokeWidth.thick)
          .pointerDown(const NPoint(0.1, 0.1))
          .pointerUp();
      final stroke = s.annotation.shapes.single as FreehandStroke;
      expect(stroke.color, AnnotationColor.blue);
      expect(stroke.width, StrokeWidth.thick);
    });

    test('a move without a down is ignored', () {
      final s = fresh();
      expect(identical(s.pointerMove(const NPoint(0.5, 0.5)), s), isTrue);
      expect(s.pointerUp().annotation, Annotation.empty);
    });
  });

  group('shapes', () {
    test('rectangle from any two corners, normalised', () {
      final s = fresh()
          .selectTool(AnnotationTool.rectangle)
          .pointerDown(const NPoint(0.8, 0.7))
          .pointerMove(const NPoint(0.2, 0.3))
          .pointerUp();
      final rect = s.annotation.shapes.single as RectangleShape;
      expect(
        rect.rect,
        const NRect(left: 0.2, top: 0.3, right: 0.8, bottom: 0.7),
      );
    });

    test('ellipse tool draws an ellipse', () {
      final s = fresh()
          .selectTool(AnnotationTool.ellipse)
          .pointerDown(const NPoint(0.1, 0.1))
          .pointerMove(const NPoint(0.5, 0.5))
          .pointerUp();
      expect(s.annotation.shapes.single, isA<EllipseShape>());
    });

    test('a degenerate drag with a shape tool commits nothing', () {
      final s = fresh()
          .selectTool(AnnotationTool.rectangle)
          .pointerDown(const NPoint(0.5, 0.5))
          .pointerMove(const NPoint(0.502, 0.502));
      expect(s.inProgress, isNull);
      expect(s.pointerUp().annotation, Annotation.empty);
    });
  });

  group('mask brush', () {
    test('commits a mask stroke and turns the mask attachment on', () {
      final s = fresh()
          .selectTool(AnnotationTool.maskBrush)
          .pointerDown(const NPoint(0.1, 0.1))
          .pointerMove(const NPoint(0.3, 0.1))
          .pointerUp();
      expect(s.annotation.shapes.single, isA<MaskStroke>());
      expect(s.annotation.hasMask, isTrue);
      expect(s.includeMask, isTrue);
      expect(s.result.includeMask, isTrue);
    });

    test('does not turn the mask on when no slot is free', () {
      final s = fresh(freeSlots: 1, keepOriginal: true)
          .selectTool(AnnotationTool.maskBrush)
          .pointerDown(const NPoint(0.1, 0.1))
          .pointerUp();
      expect(s.includeMask, isFalse);
      expect(s.slotsNeeded, 1);
    });

    test('the mask brush has no colour', () {
      final s = fresh()
          .selectTool(AnnotationTool.maskBrush)
          .pointerDown(const NPoint(0.1, 0.1))
          .pointerUp();
      expect(s.annotation.shapes.single.color, isNull);
      expect(AnnotationTool.maskBrush.usesColor, isFalse);
      expect(AnnotationTool.eraser.usesColor, isFalse);
      expect(AnnotationTool.pen.usesColor, isTrue);
    });
  });

  group('eraser', () {
    const rect = AnnotationShape.rectangle(
      rect: NRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9),
      color: AnnotationColor.blue,
    );

    test('removes the shape under the pointer', () {
      final s = fresh(
        start: const Annotation(shapes: [rect]),
      ).selectTool(AnnotationTool.eraser).pointerDown(const NPoint(0.5, 0.1));
      expect(s.annotation, Annotation.empty);
      expect(s.canUndo, isTrue);
    });

    test('a miss changes nothing', () {
      final start = fresh(
        start: const Annotation(shapes: [rect]),
      ).selectTool(AnnotationTool.eraser);
      final after = start.pointerDown(const NPoint(0.5, 0.5));
      expect(identical(after, start), isTrue);
    });

    test('the topmost shape wins', () {
      const twice = Annotation(shapes: [rect, rect]);
      final s = fresh(
        start: twice,
      ).selectTool(AnnotationTool.eraser).pointerDown(const NPoint(0.5, 0.1));
      expect(s.annotation.shapes, hasLength(1));
    });
  });

  group('history', () {
    test('undo / redo / clear', () {
      var s = fresh().pointerDown(const NPoint(0.1, 0.1)).pointerUp();
      s = s.pointerDown(const NPoint(0.2, 0.2)).pointerUp();
      expect(s.annotation.shapes, hasLength(2));

      s = s.undo();
      expect(s.annotation.shapes, hasLength(1));
      expect(s.canRedo, isTrue);

      s = s.redo();
      expect(s.annotation.shapes, hasLength(2));

      s = s.clear();
      expect(s.annotation, Annotation.empty);
      expect(s.canUndo, isTrue);
      expect(s.undo().annotation.shapes, hasLength(2));
    });

    test('undo with nothing to undo is a no-op', () {
      final s = fresh();
      expect(identical(s.undo(), s), isTrue);
      expect(identical(s.redo(), s), isTrue);
    });
  });

  group('options and slots', () {
    const shape = AnnotationShape.ellipse(
      rect: NRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
      color: AnnotationColor.red,
    );

    test('an unchecked option needs a free slot', () {
      final none = fresh(
        start: const Annotation(shapes: [shape]),
        freeSlots: 0,
      );
      expect(none.canAddMore, isFalse);
      expect(none.canToggleIncludeMask, isFalse);
      expect(none.canToggleKeepOriginal, isFalse);

      final one = fresh(start: const Annotation(shapes: [shape]), freeSlots: 1);
      expect(one.canToggleIncludeMask, isTrue);
      expect(one.canToggleKeepOriginal, isTrue);
      final withMask = one.withOptions(includeMask: true);
      expect(withMask.canAddMore, isFalse);
      // The checked one can still be unchecked; the other cannot be checked.
      expect(withMask.canToggleIncludeMask, isTrue);
      expect(withMask.canToggleKeepOriginal, isFalse);
    });

    test('the mask option needs something drawn', () {
      expect(fresh().canToggleIncludeMask, isFalse);
      expect(fresh().canToggleKeepOriginal, isTrue);
    });

    test('result drops includeMask when the annotation is empty', () {
      final s = fresh(includeMask: true, keepOriginal: true);
      expect(s.result.includeMask, isFalse);
      expect(s.result.keepOriginal, isTrue);
      expect(s.result.annotation, Annotation.empty);
    });
  });
}
