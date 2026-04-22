import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../providers/attachment_provider.dart';

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
        return _LoadedImageBlock(bytes: bytes);
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
          color:
              Theme.of(context).colorScheme.surfaceContainer,
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
  const _LoadedImageBlock({required this.bytes});

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
    final stream =
        MemoryImage(widget.bytes).resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener(
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
    ));
  }

  Future<void> _copyToClipboard() async {
    try {
      await Pasteboard.writeImage(widget.bytes);
      if (!mounted) return;
      setState(() => _justCopied = true);
      _copiedResetTimer?.cancel();
      _copiedResetTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _justCopied = false);
      });
    } catch (e) {
      _log.warning('Failed to copy image to clipboard', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to copy image')),
      );
    }
  }

  void _showFullscreen(BuildContext context) {
    showDialog(
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
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _copyToClipboard,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      _justCopied ? Icons.check : Icons.copy,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
