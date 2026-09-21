import 'dart:typed_data';

import '../models/photo_metadata.dart';

/// Reads what a photo file says about itself (EXIF) and writes it into
/// another image file, without touching the pixels.
abstract interface class IPhotoMetadataCodec {
  /// The metadata [bytes] carry, or `null` when there is nothing worth
  /// keeping (no EXIF, a format without it, a damaged block).
  PhotoMetadata? read(Uint8List bytes);

  /// A copy of the image file [bytes] whose metadata is exactly [metadata]:
  /// whatever EXIF or XMP it had is replaced, the pixels and colour profile
  /// are kept. [aiMark], when given, declares the image as made by AI.
  ///
  /// `null` when the format cannot carry metadata here, or the file is not
  /// well-formed enough to splice into.
  Uint8List? write(
    Uint8List bytes,
    PhotoMetadata metadata, {
    AiEditMark? aiMark,
  });
}
