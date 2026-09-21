import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../application/images/drawing_session.dart';
import '../../../../core/theme.dart';
import '../../../../domain/models/annotation.dart';
import '../../../rendering/annotation_painting.dart';
import '../../../rendering/ui_image_codec.dart';
import '../../widgets/keyboard.dart';

export '../../../../application/images/drawing_session.dart'
    show AnnotationResult;

/// Opens the annotation editor as a dialog. Returns `null` on cancel.
///
/// [freeSlots] is how many extra images the message can still take; the
/// "mask" and "keep original" options each need one and are disabled when
/// there is no room.
Future<AnnotationResult?> showAnnotationEditor(
  BuildContext context, {
  required Uint8List imageBytes,
  required Annotation initial,
  required bool includeMask,
  required bool keepOriginal,
  required int freeSlots,
  required String title,
}) async {
  final image = await decodeUiImage(imageBytes);
  if (!context.mounted) {
    image.dispose();
    return null;
  }
  try {
    return await showDialog<AnnotationResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final screen = MediaQuery.sizeOf(context);
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: math.min(screen.width - 48, 1100),
            height: math.min(screen.height - 48, 820),
            child: AnnotationEditor(
              image: image,
              title: title,
              initial: initial,
              includeMask: includeMask,
              keepOriginal: keepOriginal,
              freeSlots: freeSlots,
              onApply: (result) => Navigator.of(context).pop(result),
              onCancel: () => Navigator.of(context).pop(),
            ),
          ),
        );
      },
    );
  } finally {
    image.dispose();
  }
}

/// The editor itself: toolbar, drawing canvas, options and actions.
///
/// All editor logic is a [DrawingSession]; this widget maps pointer
/// positions to normalised coordinates, feeds them in and paints the
/// result. The image is passed in already decoded so the widget is
/// synchronous and the caller controls the `ui.Image` lifetime.
class AnnotationEditor extends StatefulWidget {
  final ui.Image image;
  final String title;
  final Annotation initial;
  final bool includeMask;
  final bool keepOriginal;
  final int freeSlots;
  final ValueChanged<AnnotationResult> onApply;
  final VoidCallback onCancel;

  const AnnotationEditor({
    super.key,
    required this.image,
    required this.onApply,
    required this.onCancel,
    this.title = 'Annotate image',
    this.initial = Annotation.empty,
    this.includeMask = false,
    this.keepOriginal = false,
    this.freeSlots = 2,
  });

  @override
  State<AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends State<AnnotationEditor> {
  late DrawingSession _session = DrawingSession.initial(
    aspectRatio: widget.image.width / widget.image.height,
    start: widget.initial,
    includeMask: widget.includeMask,
    keepOriginal: widget.keepOriginal,
    freeSlots: widget.freeSlots,
  );
  bool _showMask = false;

  final _focusNode = FocusNode(debugLabel: 'AnnotationEditor');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _update(DrawingSession Function(DrawingSession) change) {
    final next = change(_session);
    if (identical(next, _session)) return;
    setState(() => _session = next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    if (isPrimaryModifierPressed &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      final redo = HardwareKeyboard.instance.isShiftPressed;
      _update((s) => redo ? s.redo() : s.undo());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _session;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        children: [
          _Toolbar(
            title: widget.title,
            session: s,
            onUpdate: _update,
            showMask: _showMask,
            onToggleMask: () => setState(() => _showMask = !_showMask),
          ),
          const Divider(height: 1),
          Expanded(
            child: Container(
              color: cs.surfaceContainerLowest,
              padding: const EdgeInsets.all(12),
              child: _AnnotationCanvas(
                image: widget.image,
                annotation: s.annotation,
                inProgress: s.inProgress,
                showMask: _showMask || s.tool == AnnotationTool.maskBrush,
                cursor: s.tool == AnnotationTool.eraser
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.precise,
                onDown: (p) => _update((s) => s.pointerDown(p)),
                onMove: (p) => _update((s) => s.pointerMove(p)),
                onUp: () => _update((s) => s.pointerUp()),
              ),
            ),
          ),
          const Divider(height: 1),
          _Footer(
            session: s,
            onUpdate: _update,
            onCancel: widget.onCancel,
            onApply: () => widget.onApply(s.result),
          ),
        ],
      ),
    );
  }
}

/// Toolbar glyph and label for each tool — presentation only, so the
/// enum itself stays free of Flutter.
extension on AnnotationTool {
  IconData get icon => switch (this) {
    AnnotationTool.pen => Icons.gesture,
    AnnotationTool.ellipse => Icons.circle_outlined,
    AnnotationTool.rectangle => Icons.crop_square,
    AnnotationTool.maskBrush => Icons.brush,
    AnnotationTool.eraser => Icons.cleaning_services_outlined,
  };

  String get label => switch (this) {
    AnnotationTool.pen => 'Pen',
    AnnotationTool.ellipse => 'Ellipse',
    AnnotationTool.rectangle => 'Rectangle',
    AnnotationTool.maskBrush => 'Mask brush',
    AnnotationTool.eraser => 'Eraser',
  };
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

/// Edits the session's tool settings and history. Everything it shows is
/// read off [session]; everything it changes goes through [onUpdate].
class _Toolbar extends StatelessWidget {
  final String title;
  final DrawingSession session;
  final ValueChanged<DrawingSession Function(DrawingSession)> onUpdate;
  final bool showMask;
  final VoidCallback onToggleMask;

  const _Toolbar({
    required this.title,
    required this.session,
    required this.onUpdate,
    required this.showMask,
    required this.onToggleMask,
  });

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 16),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  SegmentedButton<AnnotationTool>(
                    segments: [
                      for (final t in AnnotationTool.values)
                        ButtonSegment(
                          value: t,
                          icon: Icon(t.icon, size: 18),
                          tooltip: t.label,
                        ),
                    ],
                    selected: {session.tool},
                    showSelectedIcon: false,
                    onSelectionChanged: (set) =>
                        onUpdate((s) => s.selectTool(set.first)),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 16),
                  for (final c in AnnotationColor.values)
                    _ColorSwatch(
                      color: c,
                      selected: c == session.color,
                      enabled: session.tool.usesColor,
                      onTap: () => onUpdate((s) => s.selectColor(c)),
                    ),
                  const SizedBox(width: 16),
                  SegmentedButton<StrokeWidth>(
                    segments: const [
                      ButtonSegment(
                        value: StrokeWidth.thin,
                        label: Text('S'),
                        tooltip: 'Thin',
                      ),
                      ButtonSegment(
                        value: StrokeWidth.medium,
                        label: Text('M'),
                        tooltip: 'Medium',
                      ),
                      ButtonSegment(
                        value: StrokeWidth.thick,
                        label: Text('L'),
                        tooltip: 'Thick',
                      ),
                    ],
                    selected: {session.width},
                    showSelectedIcon: false,
                    onSelectionChanged: (set) =>
                        onUpdate((s) => s.selectWidth(set.first)),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    tooltip: showMask
                        ? 'Hide mask preview'
                        : 'Show mask preview',
                    isSelected: showMask,
                    icon: const Icon(Icons.layers_outlined, size: 20),
                    selectedIcon: const Icon(Icons.layers, size: 20),
                    onPressed: onToggleMask,
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Undo (⌘Z)',
            icon: const Icon(Icons.undo, size: 20),
            onPressed: session.canUndo ? () => onUpdate((s) => s.undo()) : null,
          ),
          IconButton(
            tooltip: 'Redo (⇧⌘Z)',
            icon: const Icon(Icons.redo, size: 20),
            onPressed: session.canRedo ? () => onUpdate((s) => s.redo()) : null,
          ),
          IconButton(
            tooltip: 'Clear all',
            icon: Icon(Icons.delete_outline, size: 20, color: styles.textMuted),
            onPressed: session.annotation.isNotEmpty
                ? () => onUpdate((s) => s.clear())
                : null,
          ),
        ],
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final AnnotationColor color;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: color.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: Semantics(
            label: '${color.label} colour',
            selected: selected,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Color(color.argb).withValues(alpha: enabled ? 1 : 0.35),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? cs.onSurface : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

/// The image fitted in the available space with the annotation on top.
/// Pointer positions are mapped to normalised image coordinates and
/// clamped to the image, so drawing past the edge just hugs the border.
class _AnnotationCanvas extends StatelessWidget {
  final ui.Image image;
  final Annotation annotation;
  final AnnotationShape? inProgress;
  final bool showMask;
  final MouseCursor cursor;
  final ValueChanged<NPoint> onDown;
  final ValueChanged<NPoint> onMove;
  final VoidCallback onUp;

  const _AnnotationCanvas({
    required this.image,
    required this.annotation,
    required this.inProgress,
    required this.showMask,
    required this.cursor,
    required this.onDown,
    required this.onMove,
    required this.onUp,
  });

  static Rect fitRect(Size image, Size available) {
    final sizes = applyBoxFit(BoxFit.contain, image, available);
    final dst = sizes.destination;
    return Rect.fromLTWH(
      (available.width - dst.width) / 2,
      (available.height - dst.height) / 2,
      dst.width,
      dst.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    return LayoutBuilder(
      builder: (context, constraints) {
        final rect = fitRect(imageSize, constraints.biggest);
        NPoint toNormalised(Offset local) => NPoint(
          ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0),
          ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0),
        );
        return MouseRegion(
          cursor: cursor,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              if (e.buttons != kPrimaryButton) return;
              onDown(toNormalised(e.localPosition));
            },
            onPointerMove: (e) => onMove(toNormalised(e.localPosition)),
            onPointerUp: (_) => onUp(),
            onPointerCancel: (_) => onUp(),
            child: CustomPaint(
              key: const ValueKey('annotation-canvas'),
              size: constraints.biggest,
              painter: _CanvasPainter(
                image: image,
                imageRect: rect,
                annotation: annotation,
                inProgress: inProgress,
                showMask: showMask,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final ui.Image image;
  final Rect imageRect;
  final Annotation annotation;
  final AnnotationShape? inProgress;
  final bool showMask;

  const _CanvasPainter({
    required this.image,
    required this.imageRect,
    required this.annotation,
    required this.inProgress,
    required this.showMask,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      imageRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.save();
    canvas.clipRect(imageRect);
    canvas.translate(imageRect.left, imageRect.top);
    final drawSize = imageRect.size;
    if (showMask) {
      AnnotationPainting.paintMask(
        canvas,
        drawSize,
        annotation,
        color: AnnotationPainting.maskOverlayColor,
      );
    }
    AnnotationPainting.paintOutlines(canvas, drawSize, annotation);
    if (inProgress case final s?) {
      AnnotationPainting.paintShape(canvas, drawSize, s);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.image != image ||
      old.imageRect != imageRect ||
      old.annotation != annotation ||
      old.inProgress != inProgress ||
      old.showMask != showMask;
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

/// Attachment options and the dialog's actions.
class _Footer extends StatelessWidget {
  final DrawingSession session;
  final ValueChanged<DrawingSession Function(DrawingSession)> onUpdate;
  final VoidCallback onCancel;
  final VoidCallback onApply;

  const _Footer({
    required this.session,
    required this.onUpdate,
    required this.onCancel,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Option(
                  label: 'Also attach a black & white mask',
                  value: session.includeMask,
                  enabled: session.canToggleIncludeMask,
                  onChanged: (v) =>
                      onUpdate((s) => s.withOptions(includeMask: v)),
                ),
                _Option(
                  label: 'Keep the original image too',
                  value: session.keepOriginal,
                  enabled: session.canToggleKeepOriginal,
                  onChanged: (v) =>
                      onUpdate((s) => s.withOptions(keepOriginal: v)),
                ),
                if (!session.canAddMore)
                  Text('No room for more images', style: styles.smallMuted),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: onApply, child: const Text('Apply')),
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _Option({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            onChanged: enabled ? (v) => onChanged(v ?? false) : null,
            visualDensity: VisualDensity.compact,
          ),
          Text(
            label,
            style: enabled
                ? null
                : TextStyle(color: context.specterStyles.textFaint),
          ),
        ],
      ),
    );
  }
}
