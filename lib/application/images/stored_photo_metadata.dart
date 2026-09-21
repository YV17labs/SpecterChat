import 'dart:typed_data';

import '../../domain/models/message.dart'
    show DescribedImage, ImageContentBlock;
import '../../domain/models/photo_metadata.dart';
import '../../domain/repositories/i_attachment_repository.dart';
import '../chat/message_writes.dart';

// The photo metadata of an image block, as stored: what is shown on the
// block ([PhotoMetadataRef]), the verbatim blocks in an attachment of their
// own — loaded only to save the image or reuse it, copied for an image
// that inherits them.

/// The verbatim blocks behind [ref]: its attachment's, or those an earlier
/// build kept in the block itself. `null` when there are none — an image
/// attached by the very first version, which kept only what is shown.
Future<PhotoMetadataBlocks?> loadPhotoMetadataBlocks(
  IAttachmentRepository attachments,
  PhotoMetadataRef ref,
) async => switch (ref.blocksId) {
  final id? => await attachments.loadPhotoMetadata(id),
  null => ref.inlineBlocks,
};

/// [block], whose stored bytes are [bytes], with all that is known about
/// it — its photo metadata's blocks loaded — for "Annotate & reuse".
Future<DescribedImage> describeStoredImage(
  IAttachmentRepository attachments,
  ImageContentBlock block,
  Uint8List bytes,
) async => DescribedImage(
  bytes: bytes,
  mimeType: block.mimeType,
  metadata: switch (block.photoMetadata) {
    final ref? => PhotoMetadata(
      summary: ref.summary,
      blocks:
          await loadPhotoMetadataBlocks(attachments, ref) ??
          const PhotoMetadataBlocks(),
    ),
    null => null,
  },
  aiOrigin: block.aiOrigin,
);

/// [source], inherited by an image of the message [messageId]: its blocks
/// copied to the attachment [attachmentId] of that message, so the image
/// keeps them whatever becomes of the source's message. Blocks an earlier
/// build kept inline get their attachment now. The caller writes this
/// before the block that references it.
Future<PhotoMetadataRef> copyPhotoMetadata(
  IAttachmentRepository attachments,
  PhotoMetadataRef source, {
  required String attachmentId,
  required String messageId,
}) async {
  var stored = false;
  if (source.blocksId case final from?) {
    stored = await attachments.copy(
      sourceId: from,
      attachmentId: attachmentId,
      messageId: messageId,
    );
  } else if (source.inlineBlocks case final blocks?) {
    await attachments.store(
      PendingAttachment.photoMetadata(
        attachmentId: attachmentId,
        blocks: blocks,
      ),
      messageId: messageId,
    );
    stored = true;
  }
  return PhotoMetadataRef(
    summary: source.summary,
    blocksId: stored ? attachmentId : null,
  );
}
