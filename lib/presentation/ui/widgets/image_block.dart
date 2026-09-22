import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../application/images/image_export.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/photo_metadata.dart';
import '../../../domain/services/i_image_io.dart';
import '../../providers/attachment_provider.dart';
import '../../providers/image_providers.dart';
import '../../providers/image_reuse_provider.dart';
import '../../providers/settings_provider.dart';
import 'local_time_text.dart';
import 'photo_metadata_text.dart';

final _log = Logger('ImageBlock');

/// Behind everything drawn over an image on hover.
final _overlayBackground = Colors.black.withValues(alpha: 0.55);

/// Renders an image whose bytes live in the attachments table. The
/// widget watches [attachmentBytesProvider] so bytes are loaded only
/// when the widget is mounted and released shortly after it disposes.
///
/// "Save as…" writes the block's photo metadata into the file and declares
/// how a model made it, as the settings allow; "Annotate & reuse" hands
/// both to the composer.
class ImageBlock extends ConsumerWidget {
  final ImageContentBlock block;

  const ImageBlock({super.key, required this.block});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attachmentId = block.attachmentId;
    final bytesAsync = ref.watch(attachmentBytesProvider(attachmentId));
    return bytesAsync.when(
      data: (bytes) {
        if (bytes == null) return const _ImageError(label: 'Image unavailable');
        return _LoadedImageBlock(
          bytes: bytes,
          photo: block.photoMetadata?.summary,
          io: ref.watch(imageIoProvider),
          save: () => ref
              .read(imageExporterProvider)
              .save(
                block,
                bytes,
                choices: ref.read(settingsProvider).photoMetadata,
              ),
          onAnnotate: () => unawaited(
            ref.read(imageReuseProvider.notifier).request(block, bytes),
          ),
        );
      },
      loading: () => const _ImageLoadingPlaceholder(),
      error: (e, st) {
        _log.fine('Failed to load attachment $attachmentId', e, st);
        return const _ImageError(label: 'Failed to load image');
      },
    );
  }
}

class _ImageLoadingPlaceholder extends StatelessWidget {
  const _ImageLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _ImageError extends StatelessWidget {
  final String label;
  const _ImageError({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label),
    );
  }
}

class _LoadedImageBlock extends StatefulWidget {
  final Uint8List bytes;

  /// What is shown of the photo behind the image, when there is one.
  final PhotoSummary? photo;

  /// The clipboard goes through here, never a plugin directly.
  final IImageIo io;

  /// "Save as…": [bytes] with the photo metadata the user chose to keep,
  /// where the user says; what went in, or `null` when cancelled.
  final Future<ImageExport?> Function() save;

  /// Hands the image back to the composer, annotation editor open.
  final VoidCallback? onAnnotate;

  const _LoadedImageBlock({
    required this.bytes,
    required this.io,
    required this.save,
    this.photo,
    this.onAnnotate,
  });

  @override
  State<_LoadedImageBlock> createState() => _LoadedImageBlockState();
}

class _LoadedImageBlockState extends State<_LoadedImageBlock> {
  double? _aspectRatio;
  bool _hovering = false;
  bool _justCopied = false;
  Timer? _copiedResetTimer;

  @override
  void initState() {
    super.initState();
    _resolveImageDimensions();
  }

  @override
  void didUpdateWidget(covariant _LoadedImageBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _aspectRatio = null;
      _resolveImageDimensions();
    }
  }

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    super.dispose();
  }

  void _resolveImageDimensions() {
    final stream = MemoryImage(widget.bytes).resolve(ImageConfiguration.empty);
    stream.addListener(
      ImageStreamListener(
        (ImageInfo info, bool _) {
          final w = info.image.width.toDouble();
          final h = info.image.height.toDouble();
          if (h > 0 && mounted) {
            setState(() => _aspectRatio = w / h);
          }
          info.dispose();
        },
        onError: (exception, stackTrace) {
          _log.fine('Failed to resolve image dimensions', exception);
        },
      ),
    );
  }

  Future<void> _copyToClipboard() async {
    try {
      await widget.io.writeClipboardImage(widget.bytes);
      if (!mounted) return;
      setState(() => _justCopied = true);
      _copiedResetTimer?.cancel();
      _copiedResetTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _justCopied = false);
      });
    } catch (e) {
      _log.warning('Failed to copy image to clipboard', e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to copy image')));
    }
  }

  Future<void> _saveAs() async {
    try {
      final message = switch (await widget.save()) {
        final export? => savedMetadataMessage(export),
        null => null,
      };
      if (message == null || !mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      _log.warning('Failed to save image', e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to save image')));
    }
  }

  void _showFullscreen(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(16),
            child: InteractiveViewer(
              child: Image.memory(widget.bytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageWidget = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = _aspectRatio != null ? width / _aspectRatio! : null;
        return Image.memory(
          widget.bytes,
          width: width,
          height: height,
          fit: BoxFit.fitWidth,
          errorBuilder: (_, _, _) =>
              const _ImageError(label: 'Failed to decode image'),
        );
      },
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: [
          GestureDetector(
            onTap: () => _showFullscreen(context),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: imageWidget,
            ),
          ),
          if (widget.photo case final photo?)
            Positioned(
              left: 8,
              bottom: 8,
              child: AnimatedOpacity(
                opacity: _hovering ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: _MetadataBadge(photo: photo),
              ),
            ),
          Positioned(
            right: 8,
            bottom: 8,
            child: AnimatedOpacity(
              opacity: (_hovering || _justCopied) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onAnnotate case final onAnnotate?) ...[
                    _OverlayButton(
                      icon: Icons.draw_outlined,
                      tooltip: 'Annotate & reuse',
                      onTap: onAnnotate,
                    ),
                    const SizedBox(width: 6),
                  ],
                  _OverlayButton(
                    icon: Icons.save_alt,
                    tooltip: 'Save as…',
                    onTap: () => unawaited(_saveAs()),
                  ),
                  const SizedBox(width: 6),
                  _OverlayButton(
                    icon: _justCopied ? Icons.check : Icons.copy,
                    tooltip: 'Copy image',
                    onTap: _copyToClipboard,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the photo behind the image was taken, and with what: the camera
/// on the pill, the rest in its tooltip.
class _MetadataBadge extends StatelessWidget {
  final PhotoSummary photo;

  const _MetadataBadge({required this.photo});

  @override
  Widget build(BuildContext context) {
    final label = switch (photo.camera) {
      final camera? => cameraName(camera),
      null => null,
    };
    return Tooltip(
      message: photoMetadataLines(
        photo,
        locale: systemLocaleOf(context),
      ).join('\n'),
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: _overlayBackground,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              photo.location != null && label == null
                  ? Icons.place_outlined
                  : Icons.photo_camera_outlined,
              size: 14,
              color: Colors.white,
              semanticLabel: 'Photo metadata',
            ),
            if (label != null) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small translucent icon button drawn over an image on hover.
class _OverlayButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _OverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: _overlayBackground,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
