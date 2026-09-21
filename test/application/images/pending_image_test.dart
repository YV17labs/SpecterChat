import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/drawing_session.dart';
import 'package:specterchat/application/images/pending_image.dart';
import 'package:specterchat/domain/models/annotation.dart';

void main() {
  const annotation = Annotation(
    shapes: [
      AnnotationShape.mask(points: [NPoint(0.5, 0.5)]),
    ],
  );
  const full = AnnotationResult(
    annotation: annotation,
    includeMask: true,
    keepOriginal: true,
  );
  final plain = PendingImage(
    id: 'a',
    bytes: Uint8List(0),
    mimeType: 'image/png',
    name: 'a',
  );

  test('outgoingCount expands annotated entries', () {
    final drawn = plain.withAnnotation(full);
    expect(plain.outgoingCount, 1);
    expect(plain.isAnnotated, isFalse);
    expect(drawn.outgoingCount, 3);
    expect(drawn.isAnnotated, isTrue);
    expect(
      plain
          .withAnnotation(
            const AnnotationResult(
              annotation: annotation,
              includeMask: false,
              keepOriginal: true,
            ),
          )
          .outgoingCount,
      2,
    );
    expect(outgoingImageCount([plain, drawn]), 4);
  });

  test('an empty annotation clears the entry back to plain', () {
    const cleared = AnnotationResult(
      annotation: Annotation.empty,
      includeMask: true,
      keepOriginal: true,
    );
    final back = plain.withAnnotation(full).withAnnotation(cleared);
    expect(back.isAnnotated, isFalse);
    expect(back.annotation, isNull);
    expect(back.outgoingCount, 1);
  });

  test('freeImageSlots counts outgoing images against the cap', () {
    expect(freeImageSlots(const []), kMaxPendingImages);
    expect(
      freeImageSlots([plain, plain.withAnnotation(full)]),
      kMaxPendingImages - 4,
    );
  });
}
