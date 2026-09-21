import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/annotation.dart';

void main() {
  const red = AnnotationColor.red;
  const green = AnnotationColor.green;

  group('Annotation', () {
    test('JSON round-trips every shape kind', () {
      const doc = Annotation(
        shapes: [
          AnnotationShape.freehand(
            points: [NPoint(0.1, 0.2), NPoint(0.3, 0.4)],
            color: red,
            width: StrokeWidth.thin,
          ),
          AnnotationShape.ellipse(
            rect: NRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.4),
            color: green,
          ),
          AnnotationShape.rectangle(
            rect: NRect(left: 0.2, top: 0.2, right: 0.9, bottom: 0.8),
            color: AnnotationColor.magenta,
            width: StrokeWidth.thick,
          ),
          AnnotationShape.mask(points: [NPoint(0.5, 0.5), NPoint(0.6, 0.6)]),
        ],
      );
      final encoded = jsonEncode(doc.toJson());
      final decoded = Annotation.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(decoded, doc);
      // Colours are serialised by name, never by ARGB value, so the palette
      // can be retuned without breaking stored annotations.
      expect(encoded, contains('"color":"red"'));
      expect(encoded, contains('"width":"thick"'));
      expect(encoded, isNot(contains('4293')));
    });

    test('usedColors keeps first-use order and ignores mask strokes', () {
      const doc = Annotation(
        shapes: [
          AnnotationShape.mask(points: [NPoint(0, 0)]),
          AnnotationShape.ellipse(
            rect: NRect(left: 0, top: 0, right: 1, bottom: 1),
            color: green,
          ),
          AnnotationShape.freehand(points: [NPoint(0, 0)], color: red),
          AnnotationShape.rectangle(
            rect: NRect(left: 0, top: 0, right: 1, bottom: 1),
            color: green,
          ),
        ],
      );
      expect(doc.usedColors, [green, red]);
      expect(doc.hasMask, isTrue);
      expect(doc.isNotEmpty, isTrue);
    });

    test('add / removeAt return new documents', () {
      const stroke = AnnotationShape.freehand(
        points: [NPoint(0, 0)],
        color: red,
      );
      final one = Annotation.empty.add(stroke);
      expect(Annotation.empty.isEmpty, isTrue);
      expect(one.shapes, [stroke]);
      expect(one.removeAt(0), Annotation.empty);
      expect(one.add(stroke).shapes, hasLength(2));
    });

    test('NRect.fromCorners normalises the corner order', () {
      final r = NRect.fromCorners(
        const NPoint(0.8, 0.9),
        const NPoint(0.2, 0.1),
      );
      expect(r, const NRect(left: 0.2, top: 0.1, right: 0.8, bottom: 0.9));
      expect(r.width, closeTo(0.6, 1e-9));
      expect(r.center, const NPoint(0.5, 0.5));
    });

    test('stroke width scales with the image size', () {
      expect(StrokeWidth.medium.pixels(1000), 8);
      expect(StrokeWidth.thin.pixels(100), 1); // never thinner than 1 px
    });
  });
}
