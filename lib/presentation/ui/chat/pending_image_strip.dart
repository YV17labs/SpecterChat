import 'package:flutter/material.dart';

import '../../../application/images/pending_image.dart';
import '../../../core/theme.dart';
import '../widgets/photo_metadata_text.dart';

/// Horizontal row of thumbnails for the images about to be sent, each
/// with a remove button and an edit (annotate) button. Renders nothing
/// when [images] is empty.
class PendingImageStrip extends StatelessWidget {
  final List<PendingImage> images;
  final ValueChanged<String> onRemove;

  /// Opens the annotation editor for the image with this id. When `null`
  /// the edit affordance is hidden.
  final ValueChanged<String>? onEdit;
  final bool enabled;

  const PendingImageStrip({
    super.key,
    required this.images,
    required this.onRemove,
    this.onEdit,
    this.enabled = true,
  });

  static const double _thumbSize = 64;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: _thumbSize + 12,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final image = images[index];
          return _Thumbnail(
            key: ValueKey(image.id),
            image: image,
            size: _thumbSize,
            enabled: enabled,
            onRemove: () => onRemove(image.id),
            onEdit: onEdit == null ? null : () => onEdit!(image.id),
          );
        },
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final PendingImage image;
  final double size;
  final bool enabled;
  final VoidCallback onRemove;
  final VoidCallback? onEdit;

  const _Thumbnail({
    super.key,
    required this.image,
    required this.size,
    required this.enabled,
    required this.onRemove,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canEdit = enabled && onEdit != null;
    final name = switch (image.annotation) {
      null => image.name,
      final a => '${image.name} (annotated${a.includeMask ? ', + mask' : ''})',
    };
    final tooltip = switch (image.metadata) {
      null => name,
      final m => '$name\n${photoMetadataSummary(m)}',
    };
    // Pending images are up to 2048 px a side; decode them at thumbnail
    // size (2× the box, so a wide image still covers it) rather than
    // keeping a 16 MB bitmap per tile in the image cache.
    final cachePx = (2 * size * MediaQuery.devicePixelRatioOf(context)).round();
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              border: Border.all(
                color: image.isAnnotated
                    ? cs.primary
                    : cs.outline.withValues(alpha: 0.3),
                width: image.isAnnotated ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: canEdit ? onEdit : null,
              child: Image(
                image: ResizeImage(
                  MemoryImage(image.bytes),
                  width: cachePx,
                  height: cachePx,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image_outlined,
                  color: context.specterStyles.textFaint,
                ),
              ),
            ),
          ),
          if (image.isAnnotated)
            Positioned(
              top: 4,
              left: 4,
              child: _Badge(
                icon: Icons.draw_outlined,
                color: cs.primary,
                semanticLabel: 'Annotated',
              ),
            ),
          if (image.metadata != null)
            Positioned(
              bottom: 4,
              left: 4,
              child: _Badge(
                icon: Icons.photo_camera_outlined,
                color: cs.onSurface,
                semanticLabel: 'Photo metadata',
              ),
            ),
          if (onEdit != null)
            Positioned(
              bottom: -6,
              right: -6,
              child: _CornerButton(
                icon: Icons.edit_outlined,
                semanticLabel: 'Annotate image',
                enabled: canEdit,
                onTap: onEdit!,
              ),
            ),
          Positioned(
            top: -6,
            right: -6,
            child: _CornerButton(
              icon: Icons.close,
              semanticLabel: 'Remove image',
              enabled: enabled,
              onTap: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small round button hanging off a thumbnail corner (remove / annotate).
class _CornerButton extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final bool enabled;
  final VoidCallback onTap;

  const _CornerButton({
    required this.icon,
    required this.semanticLabel,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            icon,
            size: 14,
            color: enabled ? cs.onSurface : context.specterStyles.textFaint,
            semanticLabel: semanticLabel,
          ),
        ),
      ),
    );
  }
}

/// Tiny status marker drawn inside a thumbnail.
class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String semanticLabel;

  const _Badge({
    required this.icon,
    required this.color,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(icon, size: 12, color: color, semanticLabel: semanticLabel),
    );
  }
}
