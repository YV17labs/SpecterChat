import 'dart:typed_data';

import '../../domain/models/app_settings.dart' show PhotoMetadataExport;
import '../../domain/models/message.dart' show ImageContentBlock;
import '../../domain/models/photo_metadata.dart';
import '../../domain/repositories/i_attachment_repository.dart';
import '../../domain/services/i_image_io.dart';
import '../../domain/services/i_photo_metadata_codec.dart';
import 'stored_photo_metadata.dart';

/// What "Save as…" writes: the file's bytes, and what went into them so
/// the UI can say so.
class ImageExport {
  final Uint8List bytes;

  /// [bytes] carry the original photo's metadata.
  final bool keptOriginal;

  /// [bytes] declare themselves as made by AI.
  final bool markedAiEdited;

  const ImageExport(
    this.bytes, {
    this.keptOriginal = false,
    this.markedAiEdited = false,
  });
}

/// "Save as…": the original photo's metadata an image block carries, all
/// of it, written into a copy of its bytes — or none of it, as the user
/// chose — and how a model made it declared, if one did and the user wants
/// it. The stored attachment is never modified.
class ImageExporter {
  final IPhotoMetadataCodec codec;
  final IAttachmentRepository attachments;
  final IImageIo io;

  const ImageExporter(this.codec, this.attachments, this.io);

  /// Asks where to save [block], whose stored bytes are [bytes], and only
  /// then [prepare]s the file — a cancelled dialog costs nothing. `null`
  /// when the user cancelled.
  Future<ImageExport?> save(
    ImageContentBlock block,
    Uint8List bytes, {
    required PhotoMetadataExport choices,
  }) async {
    ImageExport? export;
    await io.saveImage(
      mimeType: block.mimeType,
      contents: () async =>
          (export = await prepare(block, bytes, choices: choices)).bytes,
    );
    return export;
  }

  /// The file for [block], whose stored bytes are [bytes]. Its photo
  /// metadata's blocks are loaded here, and only when they are written.
  Future<ImageExport> prepare(
    ImageContentBlock block,
    Uint8List bytes, {
    required PhotoMetadataExport choices,
  }) async {
    final metadata = block.photoMetadata;
    final mark = choices.markGeneratedAsAi ? block.aiOrigin : null;
    // Nothing known about the photo and nothing to declare: the file goes
    // out exactly as stored (a screenshot, a tool result…).
    if (metadata == null && mark == null) return ImageExport(bytes);
    final kept = choices.keepOriginal && metadata != null
        ? await loadPhotoMetadataBlocks(attachments, metadata)
        : null;
    final written = codec.write(
      bytes,
      kept ?? const PhotoMetadataBlocks(),
      aiMark: mark,
    );
    if (written == null) return ImageExport(bytes);
    return ImageExport(
      written,
      keptOriginal: kept != null && !kept.isEmpty,
      markedAiEdited: mark != null,
    );
  }
}
