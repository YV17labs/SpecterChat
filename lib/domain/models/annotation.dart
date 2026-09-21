import 'package:freezed_annotation/freezed_annotation.dart';

part 'annotation.freezed.dart';
part 'annotation.g.dart';

/// Colours an outline may be drawn in. Image-editing models are prompted
/// by colour name ("in the red area…"), so the set is small, the names are
/// unambiguous and the hex values are stable across versions.
enum AnnotationColor {
  red(0xFFE53935, 'red'),
  green(0xFF43A047, 'green'),
  blue(0xFF1E88E5, 'blue'),
  yellow(0xFFFDD835, 'yellow'),
  magenta(0xFFD81B60, 'magenta');

  const AnnotationColor(this.argb, this.label);

  /// Opaque ARGB value (`0xAARRGGBB`).
  final int argb;

  /// English colour name, as it should appear in a prompt.
  final String label;
}

/// Pen size, expressed as a fraction of the image's longest side so a
/// stroke drawn on a small preview keeps the same weight at full size.
enum StrokeWidth {
  thin(0.004),
  medium(0.008),
  thick(0.014);

  const StrokeWidth(this.fraction);

  final double fraction;

  /// Width in pixels for an image whose longest side is [longestSide].
  double pixels(double longestSide) => (longestSide * fraction).clamp(1, 1e4);
}

/// A point in normalised image coordinates: `x` and `y` are fractions of
/// the image width and height in `[0, 1]`, so the same annotation renders
/// identically on the on-screen preview and on the full-size original.
@freezed
abstract class NPoint with _$NPoint {
  const factory NPoint(double x, double y) = _NPoint;

  factory NPoint.fromJson(Map<String, dynamic> json) => _$NPointFromJson(json);
}

/// An axis-aligned rectangle in normalised image coordinates. Always
/// normalised so that `left <= right` and `top <= bottom`.
@freezed
abstract class NRect with _$NRect {
  const factory NRect({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) = _NRect;

  const NRect._();

  /// Builds a rectangle from two opposite corners in any order.
  factory NRect.fromCorners(NPoint a, NPoint b) => NRect(
    left: a.x < b.x ? a.x : b.x,
    top: a.y < b.y ? a.y : b.y,
    right: a.x < b.x ? b.x : a.x,
    bottom: a.y < b.y ? b.y : a.y,
  );

  factory NRect.fromJson(Map<String, dynamic> json) => _$NRectFromJson(json);

  double get width => right - left;
  double get height => bottom - top;
  NPoint get center => NPoint((left + right) / 2, (top + bottom) / 2);
}

/// One drawn element. Outline shapes carry a colour the prompt can refer
/// to ("in the red area…"); mask strokes carry none: they only feed the
/// optional black-and-white mask image.
@freezed
sealed class AnnotationShape with _$AnnotationShape {
  const AnnotationShape._();

  /// A free-hand polyline. Rendered open on the image; closed and filled
  /// on the mask.
  const factory AnnotationShape.freehand({
    required List<NPoint> points,
    required AnnotationColor color,
    @Default(StrokeWidth.medium) StrokeWidth width,
  }) = FreehandStroke;

  const factory AnnotationShape.ellipse({
    required NRect rect,
    required AnnotationColor color,
    @Default(StrokeWidth.medium) StrokeWidth width,
  }) = EllipseShape;

  const factory AnnotationShape.rectangle({
    required NRect rect,
    required AnnotationColor color,
    @Default(StrokeWidth.medium) StrokeWidth width,
  }) = RectangleShape;

  /// A brush stroke that only marks the region to edit. It is painted on
  /// the mask image and shown as a translucent overlay in the editor, but
  /// never drawn on the annotated reference image.
  const factory AnnotationShape.mask({
    required List<NPoint> points,
    @Default(StrokeWidth.thick) StrokeWidth width,
  }) = MaskStroke;

  factory AnnotationShape.fromJson(Map<String, dynamic> json) =>
      _$AnnotationShapeFromJson(json);

  /// Colour of an outline shape; `null` for mask strokes.
  AnnotationColor? get color => switch (this) {
    FreehandStroke(:final color) => color,
    EllipseShape(:final color) => color,
    RectangleShape(:final color) => color,
    MaskStroke() => null,
  };

  bool get isMask => this is MaskStroke;
}

/// Everything the user drew over one image, in drawing order.
///
/// Immutable: every edit returns a new document, which is what makes the
/// undo/redo history trivial (see `AnnotationHistory`).
@freezed
abstract class Annotation with _$Annotation {
  const factory Annotation({
    @Default(<AnnotationShape>[]) List<AnnotationShape> shapes,
  }) = _Annotation;

  const Annotation._();

  factory Annotation.fromJson(Map<String, dynamic> json) =>
      _$AnnotationFromJson(json);

  static const empty = Annotation();

  bool get isEmpty => shapes.isEmpty;
  bool get isNotEmpty => shapes.isNotEmpty;

  bool get hasMask => shapes.any((s) => s.isMask);

  /// Outline colours in first-use order, without duplicates — the list a
  /// prompt template should mention.
  List<AnnotationColor> get usedColors {
    final seen = <AnnotationColor>{};
    for (final s in shapes) {
      final c = s.color;
      if (c != null) seen.add(c);
    }
    return seen.toList(growable: false);
  }

  Annotation add(AnnotationShape shape) => copyWith(shapes: [...shapes, shape]);

  Annotation removeAt(int index) => copyWith(
    shapes: [
      for (var i = 0; i < shapes.length; i++)
        if (i != index) shapes[i],
    ],
  );
}
