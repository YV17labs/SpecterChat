import 'dart:typed_data';

import '../models/message.dart';

/// Validates and normalises raw image bytes before they are attached to a
/// message: unsupported formats are rejected, oversized images are
/// downscaled so they fit what the model can take.
abstract interface class IImageNormalizer {
  /// The bytes to send, with their MIME type — the input untouched when it
  /// is already acceptable — or `null` when the bytes are not a supported
  /// image.
  Future<ImageBytes?> normalize(Uint8List bytes);
}
