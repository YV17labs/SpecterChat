import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/image_mime.dart';
import '../../domain/models/message.dart' show ImageBytes;
import '../../domain/services/i_image_normalizer.dart';

/// Longest side an attached image may have before it is downscaled.
/// Matches the native resolution of current image models; anything larger
/// only costs upload time and context.
const int kMaxAttachedImageSide = 2048;

/// [IImageNormalizer] on the Flutter engine's image codec.
///
/// Returns the bytes untouched when the format is supported and the image
/// fits within [maxSide]; otherwise re-encodes a downscaled PNG (aspect
/// ratio preserved).
class UiImageNormalizer implements IImageNormalizer {
  final int maxSide;

  const UiImageNormalizer({this.maxSide = kMaxAttachedImageSide});

  @override
  Future<ImageBytes?> normalize(Uint8List bytes) async {
    final mime = sniffImageMime(bytes);
    if (mime == null) return null;

    final ui.ImageDescriptor descriptor;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      buffer.dispose();
    } catch (_) {
      return null;
    }

    final w = descriptor.width;
    final h = descriptor.height;
    if (w <= maxSide && h <= maxSide) {
      descriptor.dispose();
      return (bytes: bytes, mimeType: mime);
    }

    final scale = maxSide / math.max(w, h);
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (w * scale).round()),
        targetHeight: math.max(1, (h * scale).round()),
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return (bytes: data.buffer.asUint8List(), mimeType: 'image/png');
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor.dispose();
    }
  }
}
