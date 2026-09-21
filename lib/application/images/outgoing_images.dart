import '../../domain/models/message.dart' show ImageBytes;
import '../../domain/services/i_annotation_renderer.dart';
import 'pending_image.dart';

/// Turns the composer's pending entries into the bytes that go out with
/// the message, in order: for a plain image its bytes; for an annotated
/// one the annotated copy, then the mask (if requested), then the
/// original (if requested).
///
/// The original was already capped by the normaliser and the renderer
/// works at the original's pixel size, so nothing is rescaled here.
Future<List<ImageBytes>> expandPendingImages(
  Iterable<PendingImage> images, {
  required IAnnotationRenderer renderer,
}) async {
  final out = <ImageBytes>[];
  for (final image in images) {
    final applied = image.annotation;
    if (applied == null) {
      out.add((bytes: image.bytes, mimeType: image.mimeType));
      continue;
    }
    final render = await renderer.render(
      image.bytes,
      applied.annotation,
      includeMask: applied.includeMask,
    );
    out.add((bytes: render.annotated, mimeType: 'image/png'));
    if (render.mask case final mask?) {
      out.add((bytes: mask, mimeType: 'image/png'));
    }
    if (applied.keepOriginal) {
      out.add((bytes: image.bytes, mimeType: image.mimeType));
    }
  }
  return out;
}
