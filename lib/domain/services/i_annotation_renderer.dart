import 'dart:typed_data';

import '../models/annotation.dart';

/// What [IAnnotationRenderer.render] produces: the reference image with the
/// outlines drawn on it and, when asked for, the black-and-white mask. Both
/// are PNGs at the original's pixel size.
typedef AnnotationRender = ({Uint8List annotated, Uint8List? mask});

/// Turns an [Annotation] into the images the model receives.
///
/// The contract is here so the outgoing-images use case can be exercised
/// with a fake; the real implementation draws with the Flutter engine and
/// lives in `presentation/rendering`, next to the painter the editor shares.
abstract interface class IAnnotationRenderer {
  /// [original] with every outline shape stroked on top and, when
  /// [includeMask] is set, the mask (white where the model should edit).
  Future<AnnotationRender> render(
    Uint8List original,
    Annotation annotation, {
    bool includeMask = false,
  });
}
