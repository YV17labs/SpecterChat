import 'dart:math' as math;

import '../../domain/models/annotation.dart';

/// Geometry over normalised annotation coordinates.
///
/// Normalised space is anisotropic (x is a fraction of the width, y of
/// the height), so every distance is computed in a "unit height" space
/// where x is multiplied by the image aspect ratio (`width / height`).
/// Callers pass tolerances in that same space (a fraction of the height).
class AnnotationGeometry {
  final double aspectRatio;

  const AnnotationGeometry({required this.aspectRatio});

  /// Index of the topmost shape whose outline lies within [tolerance] of
  /// [p], or `null`. Later shapes are drawn on top, so they win.
  int? hitTest(Annotation annotation, NPoint p, {double tolerance = 0.02}) {
    for (var i = annotation.shapes.length - 1; i >= 0; i--) {
      if (distance(annotation.shapes[i], p) <= tolerance) return i;
    }
    return null;
  }

  /// Distance from [p] to the outline of [shape], in unit-height space.
  double distance(AnnotationShape shape, NPoint p) => switch (shape) {
    FreehandStroke(:final points) => _polylineDistance(points, p),
    MaskStroke(:final points) => _polylineDistance(points, p),
    RectangleShape(:final rect) => _rectDistance(rect, p),
    EllipseShape(:final rect) => _ellipseDistance(rect, p),
  };

  double _sx(double x) => x * aspectRatio;

  double _polylineDistance(List<NPoint> pts, NPoint p) {
    if (pts.isEmpty) return double.infinity;
    final px = _sx(p.x);
    final py = p.y;
    var best = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[math.min(i + 1, pts.length - 1)];
      best = math.min(
        best,
        _segmentDistance(_sx(a.x), a.y, _sx(b.x), b.y, px, py),
      );
    }
    return best;
  }

  static double _segmentDistance(
    double ax,
    double ay,
    double bx,
    double by,
    double px,
    double py,
  ) {
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx;
    final cy = ay + t * dy;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  double _rectDistance(NRect r, NPoint p) {
    final l = _sx(r.left), rt = _sx(r.right), t = r.top, b = r.bottom;
    final px = _sx(p.x), py = p.y;
    return [
      _segmentDistance(l, t, rt, t, px, py),
      _segmentDistance(rt, t, rt, b, px, py),
      _segmentDistance(rt, b, l, b, px, py),
      _segmentDistance(l, b, l, t, px, py),
    ].reduce(math.min);
  }

  /// Approximate distance to an ellipse outline: radial distance from the
  /// point to the ellipse along the ray from its centre. Exact enough for
  /// an eraser tolerance, and cheap.
  double _ellipseDistance(NRect r, NPoint p) {
    final cx = _sx(r.center.x), cy = r.center.y;
    final rx = _sx(r.width) / 2, ry = r.height / 2;
    if (rx <= 0 || ry <= 0) return _rectDistance(r, p);
    final dx = _sx(p.x) - cx, dy = p.y - cy;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d == 0) return math.min(rx, ry);
    final ux = dx / d, uy = dy / d;
    // Radius of the ellipse in that direction.
    final k = 1 / math.sqrt((ux * ux) / (rx * rx) + (uy * uy) / (ry * ry));
    return (d - k).abs();
  }
}
