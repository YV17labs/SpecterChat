import '../../domain/models/message.dart' show DescribedImage;
import 'drawing_session.dart' show AnnotationResult;

/// Upper bound on images attached to one message, counting the extra
/// copies an annotation may add (see [PendingImage.outgoingCount]).
const int kMaxPendingImages = 10;

/// An image the user attached to the message being composed. [image] is
/// the validated/downscaled original (see `IImageNormalizer`) with what is
/// known about it: the photo metadata read from the file before the
/// normaliser may have re-encoded it away — or, for an image of the
/// conversation reused, its metadata and how a model made it. What the
/// editor produced, if anything, is kept separately
/// in [annotation] and only rendered onto a copy when the message is sent
/// (`expandPendingImages`), so the editor can be reopened on the untouched
/// original.
class PendingImage {
  final String id;

  /// Display name (file name, or a synthetic one for pasted images).
  final String name;
  final DescribedImage image;

  /// The editor's result — outlines / mask strokes plus which extra images
  /// to send with the annotated copy. Never holds an empty annotation:
  /// "nothing drawn" is `null`.
  final AnnotationResult? annotation;

  const PendingImage({
    required this.id,
    required this.name,
    required this.image,
    this.annotation,
  });

  bool get isAnnotated => annotation != null;

  /// How many images this entry becomes once sent.
  int get outgoingCount => switch (annotation) {
    null => 1,
    final a => 1 + (a.includeMask ? 1 : 0) + (a.keepOriginal ? 1 : 0),
  };

  /// The same image with [result] applied; an empty annotation clears it.
  PendingImage withAnnotation(AnnotationResult result) => PendingImage(
    id: id,
    name: name,
    image: image,
    annotation: result.annotation.isEmpty ? null : result,
  );
}

/// Total number of images a list of pending entries will send.
int outgoingImageCount(Iterable<PendingImage> images) =>
    images.fold(0, (n, i) => n + i.outgoingCount);

/// Images the message can still take.
int freeImageSlots(Iterable<PendingImage> images) =>
    kMaxPendingImages - outgoingImageCount(images);
