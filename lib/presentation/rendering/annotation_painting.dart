import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../domain/models/annotation.dart';

/// Draws an [Annotation] onto a canvas of any pixel size.
///
/// Single source of truth for the visuals: the on-screen editor
/// (`CustomPainter`) and the full-size export (`UiAnnotationRenderer`)
/// both go through these functions, so what the user sees is exactly what
/// the model receives.
abstract final class AnnotationPainting {
  /// Fill colour of the mask overlay shown in the editor.
  static const ui.Color maskOverlayColor = ui.Color(0x80FFFFFF);

  /// Strokes every outline shape (freehand, ellipse, rectangle) in its
  /// colour. Mask strokes are skipped — they never appear on the image.
  static void paintOutlines(
    ui.Canvas canvas,
    ui.Size size,
    Annotation annotation,
  ) {
    for (final shape in annotation.shapes) {
      if (shape.isMask) continue;
      paintShape(canvas, size, shape);
    }
  }

  /// Strokes one shape (any kind, including a mask stroke rendered as a
  /// translucent brush). Used for the in-progress shape while dragging.
  static void paintShape(ui.Canvas canvas, ui.Size size, AnnotationShape s) {
    final color = s.color;
    final paint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..isAntiAlias = true
      ..color = color == null ? maskOverlayColor : ui.Color(color.argb)
      ..strokeWidth = s.width.pixels(math.max(size.width, size.height));
    switch (s) {
      case FreehandStroke(:final points) || MaskStroke(:final points):
        _strokePolyline(canvas, size, points, paint);
      case EllipseShape(:final rect):
        canvas.drawOval(_rect(rect, size), paint);
      case RectangleShape(:final rect):
        canvas.drawRect(_rect(rect, size), paint);
    }
  }

  /// Paints the edit region in [color]: outline shapes are filled (a
  /// freehand stroke is closed first), mask strokes are painted with their
  /// brush width. With an opaque white on black this is the exported mask;
  /// with [maskOverlayColor] on top of the image it is the editor preview.
  static void paintMask(
    ui.Canvas canvas,
    ui.Size size,
    Annotation annotation, {
    ui.Color color = const ui.Color(0xFFFFFFFF),
  }) {
    final fill = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.fill
      ..isAntiAlias = true;
    final stroke = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..isAntiAlias = true;
    final longest = math.max(size.width, size.height);
    for (final s in annotation.shapes) {
      switch (s) {
        case FreehandStroke(:final points, :final width):
          final path = _polylinePath(size, points)..close();
          canvas.drawPath(path, fill);
          // The outline itself counts as part of the region, so a thin
          // open scribble still produces a usable mask.
          stroke.strokeWidth = width.pixels(longest);
          canvas.drawPath(path, stroke);
        case EllipseShape(:final rect):
          canvas.drawOval(_rect(rect, size), fill);
        case RectangleShape(:final rect):
          canvas.drawRect(_rect(rect, size), fill);
        case MaskStroke(:final points, :final width):
          stroke.strokeWidth = width.pixels(longest);
          _strokePolyline(canvas, size, points, stroke);
      }
    }
  }

  static ui.Rect _rect(NRect r, ui.Size size) => ui.Rect.fromLTRB(
    r.left * size.width,
    r.top * size.height,
    r.right * size.width,
    r.bottom * size.height,
  );

  static ui.Path _polylinePath(ui.Size size, List<NPoint> points) {
    final path = ui.Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.x * size.width, points.first.y * size.height);
    for (final p in points.skip(1)) {
      path.lineTo(p.x * size.width, p.y * size.height);
    }
    return path;
  }

  static void _strokePolyline(
    ui.Canvas canvas,
    ui.Size size,
    List<NPoint> points,
    ui.Paint paint,
  ) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      // A click without a drag: a dot the size of the brush.
      final p = points.first;
      canvas.drawCircle(
        ui.Offset(p.x * size.width, p.y * size.height),
        paint.strokeWidth / 2,
        ui.Paint()
          ..color = paint.color
          ..style = ui.PaintingStyle.fill
          ..isAntiAlias = true,
      );
      return;
    }
    canvas.drawPath(_polylinePath(size, points), paint);
  }
}
