import '../../domain/models/message.dart' show OutgoingImage;
import '../../domain/services/i_annotation_renderer.dart';
import 'pending_image.dart';

/// Turns the composer's pending entries into the images that go out with
/// the message, in order: for a plain image its bytes; for an annotated
/// one the annotated copy, then the mask (if requested), then the
/// original (if requested). The copies carry the original's metadata; the
/// mask, which is not a picture of anything, does not.
///
/// The original was already capped by the normaliser and the renderer
/// works at the original's pixel size, so nothing is rescaled here.
Future<List<OutgoingImage>> expandPendingImages(
  Iterable<PendingImage> images, {
  required IAnnotationRenderer renderer,
}) async {
  final out = <OutgoingImage>[];
  for (final image in images) {
    final original = OutgoingImage(
      bytes: image.bytes,
      mimeType: image.mimeType,
      metadata: image.metadata,
    );
    final applied = image.annotation;
    if (applied == null) {
      out.add(original);
      continue;
    }
    final render = await renderer.render(
      image.bytes,
      applied.annotation,
      includeMask: applied.includeMask,
    );
    out.add(
      OutgoingImage(
        bytes: render.annotated,
        mimeType: 'image/png',
        metadata: image.metadata,
      ),
    );
    if (render.mask case final mask?) {
      out.add(OutgoingImage(bytes: mask, mimeType: 'image/png'));
    }
    if (applied.keepOriginal) out.add(original);
  }
  return out;
}
