import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/annotation.dart';
import 'package:specterchat/presentation/ui/chat/annotation/annotation_editor.dart';

import '../../../../support/image_fixtures.dart';
import '../../../../support/pump_app.dart';

void main() {
  late ui.Image image;

  Future<List<AnnotationResult?>> pumpEditor(
    WidgetTester tester, {
    Annotation initial = Annotation.empty,
    int freeSlots = 2,
  }) async {
    image = (await tester.runAsync(() => uiImageFixture(200, 100)))!;
    final results = <AnnotationResult?>[];
    await pumpApp(
      tester,
      SizedBox(
        width: 800,
        height: 600,
        child: AnnotationEditor(
          image: image,
          initial: initial,
          freeSlots: freeSlots,
          onApply: results.add,
          onCancel: () => results.add(null),
        ),
      ),
    );
    await tester.pump();
    return results;
  }

  Finder canvas() => find.byKey(const ValueKey('annotation-canvas'));

  tearDown(() => image.dispose());

  testWidgets(
    'a drag with the pen becomes a freehand stroke; undo removes it',
    (tester) async {
      final results = await pumpEditor(tester);
      final origin = tester.getCenter(canvas());
      await tester.timedDragFrom(
        origin,
        const Offset(80, 30),
        const Duration(milliseconds: 200),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Undo (⌘Z)'));
      await tester.pump();
      await tester.tap(find.byTooltip('Redo (⇧⌘Z)'));
      await tester.pump();

      await tester.tap(find.text('Apply'));
      await tester.pump();
      expect(results, hasLength(1));
      final annotation = results.single!.annotation;
      expect(annotation.shapes, hasLength(1));
      final stroke = annotation.shapes.single as FreehandStroke;
      expect(stroke.color, AnnotationColor.red);
      expect(stroke.points.length, greaterThan(2));
      // All points inside the image and moving right/down from the centre.
      for (final p in stroke.points) {
        expect(p.x, inInclusiveRange(0, 1));
        expect(p.y, inInclusiveRange(0, 1));
      }
      expect(stroke.points.last.x, greaterThan(stroke.points.first.x));
      expect(results.single!.includeMask, isFalse);
    },
  );

  testWidgets('undo then apply yields an empty annotation', (tester) async {
    final results = await pumpEditor(tester);
    await tester.timedDragFrom(
      tester.getCenter(canvas()),
      const Offset(40, 0),
      const Duration(milliseconds: 100),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Undo (⌘Z)'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    expect(results.single!.annotation, Annotation.empty);
  });

  testWidgets('rectangle tool + colour swatch + mask brush', (tester) async {
    final results = await pumpEditor(tester);
    await tester.tap(find.byTooltip('Rectangle'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('green colour'));
    await tester.pump();
    final origin = tester.getCenter(canvas()) - const Offset(50, 20);
    await tester.timedDragFrom(
      origin,
      const Offset(100, 40),
      const Duration(milliseconds: 100),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Mask brush'));
    await tester.pump();
    await tester.timedDragFrom(
      tester.getCenter(canvas()),
      const Offset(30, 0),
      const Duration(milliseconds: 100),
    );
    await tester.pump();

    await tester.tap(find.text('Apply'));
    final result = results.single!;
    expect(result.annotation.shapes, hasLength(2));
    final rect = result.annotation.shapes.first as RectangleShape;
    expect(rect.color, AnnotationColor.green);
    expect(rect.rect.width, greaterThan(0.1));
    expect(result.annotation.shapes.last, isA<MaskStroke>());
    // Painting a mask region auto-enables the mask attachment.
    expect(result.includeMask, isTrue);
  });

  testWidgets('eraser removes the shape under the pointer', (tester) async {
    const initial = Annotation(
      shapes: [
        AnnotationShape.rectangle(
          rect: NRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9),
          color: AnnotationColor.blue,
        ),
      ],
    );
    final results = await pumpEditor(tester, initial: initial);
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pump();
    // Click on the top edge of the rectangle (y = 0.1 of the fitted image).
    final box = tester.getRect(canvas());
    // The 200×100 image fitted in the canvas keeps a 2:1 box centred.
    final fitted = Rect.fromCenter(
      center: box.center,
      width: box.width,
      height: box.width / 2,
    );
    await tester.tapAt(
      Offset(fitted.center.dx, fitted.top + fitted.height * 0.1),
    );
    await tester.pump();
    await tester.tap(find.text('Apply'));
    expect(results.single!.annotation, Annotation.empty);
  });

  testWidgets('Escape cancels, Cmd+Z undoes', (tester) async {
    final results = await pumpEditor(tester);
    await tester.timedDragFrom(
      tester.getCenter(canvas()),
      const Offset(40, 0),
      const Duration(milliseconds: 100),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    final redo = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Redo (⇧⌘Z)'),
        matching: find.byType(IconButton),
      ),
    );
    expect(redo.onPressed, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(results, [null]);
  });

  testWidgets('options need free slots', (tester) async {
    const initial = Annotation(
      shapes: [
        AnnotationShape.ellipse(
          rect: NRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
          color: AnnotationColor.red,
        ),
      ],
    );
    await pumpEditor(tester, initial: initial, freeSlots: 0);
    final mask = tester.widget<Checkbox>(find.byType(Checkbox).first);
    expect(mask.onChanged, isNull);
    expect(find.text('No room for more images'), findsOneWidget);
  });
}
