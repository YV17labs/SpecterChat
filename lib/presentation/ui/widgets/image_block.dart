import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../domain/services/i_image_io.dart';
import '../../providers/attachment_provider.dart';
import '../../providers/image_providers.dart';
import '../../providers/image_reuse_provider.dart';

final _log = Logger('ImageBlock');

/// Renders an image whose bytes live in the attachments table. The
/// widget watches [attachmentBytesProvider] so bytes are loaded only
/// when the widget is mounted and released shortly after it disposes.
class ImageBlock extends ConsumerWidget {
  final String attachmentId;
  final String mimeType;

  const ImageBlock({
    super.key,
    required this.attachmentId,
    required this.mimeType,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(attachmentBytesProvider(attachmentId));
    return bytesAsync.when(
      data: (bytes) {
        if (bytes == null) return const _ImageError(label: 'Image unavailable');
        return _LoadedImageBlock(
          bytes: bytes,
          mimeType: mimeType,
          io: ref.watch(imageIoProvider),
          onAnnotate: () =>
              ref.read(imageReuseProvider.notifier).request(bytes, mimeType),
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
  final String mimeType;

  /// Clipboard and "Save as…" go through here, never a plugin directly.
  final IImageIo io;

  /// Hands the image back to the composer, annotation editor open.
  final VoidCallback? onAnnotate;

  const _LoadedImageBlock({
    required this.bytes,
    required this.mimeType,
    required this.io,
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
      await widget.io.saveImage((
        bytes: widget.bytes,
        mimeType: widget.mimeType,
      ));
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
        color: Colors.black.withValues(alpha: 0.55),
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
