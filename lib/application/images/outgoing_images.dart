import '../../domain/models/message.dart' show DescribedImage;
import '../../domain/services/i_annotation_renderer.dart';
import 'pending_image.dart';

/// Turns the composer's pending entries into the images that go out with
/// the message, in order: for a plain image its bytes; for an annotated
/// one the annotated copy, then the mask (if requested), then the
/// original (if requested). The copies carry the original's metadata and
/// AI origin; the mask, which is not a picture of anything, carries
/// neither.
///
/// The original was already capped by the normaliser and the renderer
/// works at the original's pixel size, so nothing is rescaled here.
Future<List<DescribedImage>> expandPendingImages(
  Iterable<PendingImage> images, {
  required IAnnotationRenderer renderer,
}) async {
  final out = <DescribedImage>[];
  for (final PendingImage(image: original, annotation: applied) in images) {
    if (applied == null) {
      out.add(original);
      continue;
    }
    final render = await renderer.render(
      original.bytes,
      applied.annotation,
      includeMask: applied.includeMask,
    );
    out.add(original.withBytes(render.annotated, 'image/png'));
    if (render.mask case final mask?) {
      out.add(DescribedImage(bytes: mask, mimeType: 'image/png'));
    }
    if (applied.keepOriginal) out.add(original);
  }
  return out;
}
