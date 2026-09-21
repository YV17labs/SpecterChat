import '../../domain/models/annotation.dart';
import 'annotation_geometry.dart';
import 'annotation_history.dart';

/// Drawing tools of the annotation editor.
enum AnnotationTool {
  pen,
  ellipse,
  rectangle,
  maskBrush,
  eraser;

  /// Tools that draw with a colour (as opposed to the mask brush/eraser).
  bool get usesColor => this == pen || this == ellipse || this == rectangle;
}

/// What the user decided when closing the editor with "Apply".
class AnnotationResult {
  final Annotation annotation;

  /// Also attach a black-and-white mask image.
  final bool includeMask;

  /// Also attach the untouched original next to the annotated copy.
  final bool keepOriginal;

  const AnnotationResult({
    required this.annotation,
    required this.includeMask,
    required this.keepOriginal,
  });
}

/// The annotation editor's state machine: tool settings, undo history,
/// the gesture in progress and the attachment options.
///
/// Immutable — every input returns a new session — so the widget only has
/// to `setState` around it, and every transition (a drag becoming a
/// shape, the eraser hitting an outline, an option needing a free slot)
/// is testable without a canvas. Pointer positions are normalised image
/// coordinates; mapping from pixels is the widget's job.
class DrawingSession {
  final AnnotationHistory history;
  final AnnotationTool tool;
  final AnnotationColor color;
  final StrokeWidth width;

  /// Attach the mask image next to the annotated copy.
  final bool includeMask;

  /// Attach the untouched original next to the annotated copy.
  final bool keepOriginal;

  /// Extra images the message can still take; the two options above
  /// need one each.
  final int freeSlots;

  /// `width / height` of the image, so eraser distances are isotropic.
  final double aspectRatio;

  // In-progress gesture: a polyline for pen/mask, a drag for the shapes.
  final List<NPoint>? _points;
  final NPoint? _dragStart;
  final NPoint? _dragCurrent;

  /// Eraser reach, as a fraction of the image height.
  static const double eraserTolerance = 0.025;

  /// Pointer moves closer than this (per axis) are dropped so long
  /// strokes stay light.
  static const double _jitter = 0.001;

  /// A drag smaller than this on both axes is a click, not a shape.
  static const double _minDrag = 0.005;

  const DrawingSession._({
    required this.history,
    required this.tool,
    required this.color,
    required this.width,
    required this.includeMask,
    required this.keepOriginal,
    required this.freeSlots,
    required this.aspectRatio,
    List<NPoint>? points,
    NPoint? dragStart,
    NPoint? dragCurrent,
  }) : _points = points,
       _dragStart = dragStart,
       _dragCurrent = dragCurrent;

  DrawingSession.initial({
    required double aspectRatio,
    Annotation start = Annotation.empty,
    bool includeMask = false,
    bool keepOriginal = false,
    int freeSlots = 2,
  }) : this._(
         history: AnnotationHistory.initial(start),
         tool: AnnotationTool.pen,
         color: AnnotationColor.red,
         width: StrokeWidth.medium,
         includeMask: includeMask,
         keepOriginal: keepOriginal,
         freeSlots: freeSlots,
         aspectRatio: aspectRatio,
       );

  DrawingSession _copy({
    AnnotationHistory? history,
    AnnotationTool? tool,
    AnnotationColor? color,
    StrokeWidth? width,
    bool? includeMask,
    bool? keepOriginal,
    List<NPoint>? points,
    NPoint? dragStart,
    NPoint? dragCurrent,
    bool clearGesture = false,
  }) => DrawingSession._(
    history: history ?? this.history,
    tool: tool ?? this.tool,
    color: color ?? this.color,
    width: width ?? this.width,
    includeMask: includeMask ?? this.includeMask,
    keepOriginal: keepOriginal ?? this.keepOriginal,
    freeSlots: freeSlots,
    aspectRatio: aspectRatio,
    points: clearGesture ? null : (points ?? _points),
    dragStart: clearGesture ? null : (dragStart ?? _dragStart),
    dragCurrent: clearGesture ? null : (dragCurrent ?? _dragCurrent),
  );

  // --- Derived state ---------------------------------------------------

  Annotation get annotation => history.present;
  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;
  bool get isDrawing => _points != null || _dragStart != null;

  int get slotsNeeded => (includeMask ? 1 : 0) + (keepOriginal ? 1 : 0);

  /// An unchecked option can only be checked while a slot is free.
  bool get canAddMore => slotsNeeded < freeSlots;

  bool get canToggleIncludeMask =>
      annotation.isNotEmpty && (includeMask || canAddMore);

  bool get canToggleKeepOriginal => keepOriginal || canAddMore;

  /// The shape being drawn right now, or `null` when idle. Degenerate
  /// drags (a click with a shape tool) yield nothing.
  AnnotationShape? get inProgress {
    if (_points case final pts?) {
      return tool == AnnotationTool.maskBrush
          ? AnnotationShape.mask(points: pts, width: width)
          : AnnotationShape.freehand(points: pts, color: color, width: width);
    }
    if (_dragStart case final a?) {
      final rect = NRect.fromCorners(a, _dragCurrent ?? a);
      if (rect.width < _minDrag && rect.height < _minDrag) return null;
      return tool == AnnotationTool.ellipse
          ? AnnotationShape.ellipse(rect: rect, color: color, width: width)
          : AnnotationShape.rectangle(rect: rect, color: color, width: width);
    }
    return null;
  }

  AnnotationResult get result => AnnotationResult(
    annotation: annotation,
    includeMask: includeMask && annotation.isNotEmpty,
    keepOriginal: keepOriginal,
  );

  // --- Tool settings ---------------------------------------------------

  DrawingSession selectTool(AnnotationTool t) => _copy(tool: t);
  DrawingSession selectColor(AnnotationColor c) => _copy(color: c);
  DrawingSession selectWidth(StrokeWidth w) => _copy(width: w);

  /// Attachment options; a `null` leaves that option as it is.
  DrawingSession withOptions({bool? includeMask, bool? keepOriginal}) =>
      _copy(includeMask: includeMask, keepOriginal: keepOriginal);

  // --- History ---------------------------------------------------------

  DrawingSession undo() => canUndo ? _copy(history: history.undo()) : this;
  DrawingSession redo() => canRedo ? _copy(history: history.redo()) : this;
  DrawingSession clear() => _commit(Annotation.empty);

  /// Records [next] and, when it introduces a mask region, turns the mask
  /// attachment on if a slot is free — painting a mask is a clear signal
  /// the user wants it sent.
  DrawingSession _commit(Annotation next) {
    final wantsMask = next.hasMask && !includeMask && canAddMore;
    return _copy(
      history: history.push(next),
      includeMask: wantsMask ? true : null,
    );
  }

  // --- Pointer input ---------------------------------------------------

  DrawingSession pointerDown(NPoint p) => switch (tool) {
    AnnotationTool.pen || AnnotationTool.maskBrush => _copy(points: [p]),
    AnnotationTool.ellipse ||
    AnnotationTool.rectangle => _copy(dragStart: p, dragCurrent: p),
    AnnotationTool.eraser => _erase(p),
  };

  DrawingSession pointerMove(NPoint p) {
    if (_points case final pts?) {
      final last = pts.last;
      if ((last.x - p.x).abs() < _jitter && (last.y - p.y).abs() < _jitter) {
        return this;
      }
      return _copy(points: [...pts, p]);
    }
    if (_dragStart != null) return _copy(dragCurrent: p);
    return this;
  }

  DrawingSession pointerUp() {
    final shape = inProgress;
    final idle = _copy(clearGesture: true);
    return shape == null ? idle : idle._commit(annotation.add(shape));
  }

  DrawingSession _erase(NPoint p) {
    final hit = AnnotationGeometry(
      aspectRatio: aspectRatio,
    ).hitTest(annotation, p, tolerance: eraserTolerance);
    return hit == null ? this : _commit(annotation.removeAt(hit));
  }
}
