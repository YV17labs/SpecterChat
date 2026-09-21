import '../../domain/models/app_settings.dart' show PhotoMetadataExport;
import '../../domain/models/message.dart' show ImageBytes;
import '../../domain/models/photo_metadata.dart';
import '../../domain/services/i_photo_metadata_codec.dart';

/// What "Save as…" writes: the file, and what went into it so the UI can
/// say so.
class ImageExport {
  final ImageBytes image;

  /// [image] carries the original photo's metadata.
  final bool keptOriginal;

  /// [image] declares itself as made by AI.
  final bool markedAiEdited;

  const ImageExport(
    this.image, {
    this.keptOriginal = false,
    this.markedAiEdited = false,
  });
}

/// Prepares an image for "Save as…": the original photo's metadata its
/// block carries, all of it, written into a copy of its bytes — or none of
/// it, as the user chose. The stored attachment is never modified.
class ImageExporter {
  final IPhotoMetadataCodec codec;

  const ImageExporter(this.codec);

  /// [metadata] is the image block's; [generated] says the model made the
  /// image (only those can be declared as made by AI).
  ImageExport prepare(
    ImageBytes image, {
    required PhotoMetadata? metadata,
    required bool generated,
    required PhotoMetadataExport choices,
  }) {
    final mark = generated && choices.markGeneratedAsAi
        ? (metadata == null ? AiEditMark.generated : AiEditMark.editedPhoto)
        : null;
    // Nothing known about the photo and nothing to declare: the file goes
    // out exactly as stored (a screenshot, a tool result…).
    if (metadata == null && mark == null) return ImageExport(image);
    final kept = choices.keepOriginal ? metadata : null;
    final bytes = codec.write(
      image.bytes,
      kept ?? const PhotoMetadata(),
      aiMark: mark,
    );
    if (bytes == null) return ImageExport(image);
    return ImageExport(
      (bytes: bytes, mimeType: image.mimeType),
      keptOriginal: kept != null,
      markedAiEdited: mark != null,
    );
  }
}
