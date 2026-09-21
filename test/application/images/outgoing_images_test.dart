import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/drawing_session.dart';
import 'package:specterchat/application/images/outgoing_images.dart';
import 'package:specterchat/application/images/pending_image.dart';
import 'package:specterchat/domain/models/annotation.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';

import '../../support/fakes.dart';

void main() {
  const annotation = Annotation(
    shapes: [
      AnnotationShape.rectangle(
        rect: NRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
        color: AnnotationColor.red,
      ),
    ],
  );
  final original = Uint8List.fromList([1, 2, 3]);
  final plain = PendingImage(
    id: 'p',
    bytes: original,
    mimeType: 'image/jpeg',
    name: 'p',
  );
  PendingImage annotated({bool mask = false, bool original = false}) =>
      plain.withAnnotation(
        AnnotationResult(
          annotation: annotation,
          includeMask: mask,
          keepOriginal: original,
        ),
      );

  test('a plain image goes out as is', () async {
    final renderer = FakeAnnotationRenderer();
    final out = await expandPendingImages([plain], renderer: renderer);
    expect(out.single.bytes, same(original));
    expect(out.single.mimeType, 'image/jpeg');
    expect(renderer.rendered, isEmpty);
  });

  test('annotated copy, then mask, then original — in that order', () async {
    final renderer = FakeAnnotationRenderer();
    final drawn = annotated(mask: true, original: true);
    final out = await expandPendingImages([plain, drawn], renderer: renderer);
    expect(out, hasLength(4));
    expect(out[0].bytes, same(original));
    expect(out[1].mimeType, 'image/png');
    expect(out[1].bytes.last, FakeAnnotationRenderer.annotatedMarker);
    expect(out[2].mimeType, 'image/png');
    expect(out[2].bytes, FakeAnnotationRenderer.maskBytes);
    expect(out[3].bytes, same(original));
    expect(out[3].mimeType, 'image/jpeg');
    expect(renderer.rendered, [annotation]);
  });

  test('options without the other are honoured independently', () async {
    final renderer = FakeAnnotationRenderer();
    final out = await expandPendingImages([
      annotated(mask: true),
      annotated(original: true),
    ], renderer: renderer);
    expect(out.map((i) => i.mimeType), [
      'image/png',
      'image/png',
      'image/png',
      'image/jpeg',
    ]);
  });

  test('an empty annotation sends the original untouched', () async {
    final renderer = FakeAnnotationRenderer();
    final out = await expandPendingImages([
      plain.withAnnotation(
        const AnnotationResult(
          annotation: Annotation.empty,
          includeMask: true,
          keepOriginal: false,
        ),
      ),
    ], renderer: renderer);
    expect(out.single.bytes, same(original));
    expect(renderer.rendered, isEmpty);
  });

  test("the copies carry the photo's metadata, the mask does not", () async {
    const metadata = PhotoMetadata(camera: CameraInfo(model: 'iPhone 17'));
    final photo = PendingImage(
      id: 'p',
      bytes: original,
      mimeType: 'image/jpeg',
      name: 'p',
      metadata: metadata,
    );
    final out = await expandPendingImages([
      photo.withAnnotation(
        const AnnotationResult(
          annotation: annotation,
          includeMask: true,
          keepOriginal: true,
        ),
      ),
    ], renderer: FakeAnnotationRenderer());
    expect(out.map((i) => i.metadata), [metadata, null, metadata]);
  });

  test('a renderer failure propagates so the caller can restore the draft', () {
    final renderer = FakeAnnotationRenderer()..failWith = Exception('gpu');
    expect(
      expandPendingImages([annotated()], renderer: renderer),
      throwsException,
    );
  });
}
