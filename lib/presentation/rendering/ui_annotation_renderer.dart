import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../domain/models/annotation.dart';
import '../../domain/services/i_annotation_renderer.dart';
import 'annotation_painting.dart';
import 'ui_image_codec.dart';

/// [IAnnotationRenderer] on the Flutter engine's canvas, through the same
/// [AnnotationPainting] the editor paints with — so the exported PNGs are
/// pixel-for-pixel what the user saw.
class UiAnnotationRenderer implements IAnnotationRenderer {
  const UiAnnotationRenderer();

  @override
  Future<AnnotationRender> render(
    Uint8List original,
    Annotation annotation, {
    bool includeMask = false,
  }) async {
    final image = await decodeUiImage(original);
    try {
      return (
        annotated: await renderAnnotatedUiImage(image, annotation),
        mask: includeMask
            ? await renderMask(annotation, image.width, image.height)
            : null,
      );
    } finally {
      image.dispose();
    }
  }

  /// The decoded image with the annotation's outlines stroked on top, as a
  /// PNG at its pixel size.
  static Future<Uint8List> renderAnnotatedUiImage(
    ui.Image image,
    Annotation annotation,
  ) {
    final size = ui.Size(image.width.toDouble(), image.height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(image, ui.Offset.zero, ui.Paint());
    AnnotationPainting.paintOutlines(canvas, size, annotation);
    return encodeRecordingAsPng(recorder, image.width, image.height);
  }

  /// A black-and-white mask PNG of the given size: white where the model
  /// should edit (filled outlines + mask strokes), black elsewhere.
  static Future<Uint8List> renderMask(
    Annotation annotation,
    int width,
    int height,
  ) {
    final size = ui.Size(width.toDouble(), height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    AnnotationPainting.paintMask(canvas, size, annotation);
    return encodeRecordingAsPng(recorder, width, height);
  }
}
