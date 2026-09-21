import 'dart:typed_data';

import '../models/message.dart' show ImageBytesMap;
import '../models/photo_metadata.dart' show PhotoMetadataBlocks;

/// Persistence contract for binary attachments: images, and the photo
/// metadata that goes with them ([PhotoMetadataBlocks.mimeType]).
///
/// Attachments live in their own table so `Message.content` JSON can
/// stay small — it carries only attachment ids, never bytes. Bytes are
/// loaded on demand (for display or when building an API request) and
/// deleted via FK cascade when their owning message is removed.
abstract interface class IAttachmentRepository {
  /// Store [bytes] bound to [messageId]. If [attachmentId] is omitted,
  /// a fresh id is generated; otherwise the caller-provided id is used
  /// (the tool-executor needs this so the id can be baked into the
  /// message's content JSON before the bytes are written to disk).
  /// Returns the id under which the attachment was stored.
  Future<String> storeBytes({
    String? attachmentId,
    required String messageId,
    required Uint8List bytes,
    required String mimeType,
  });

  /// A copy of the attachment [sourceId] under [attachmentId], bound to
  /// [messageId]: it lives as long as that message, whatever becomes of
  /// the source's. `false` when [sourceId] does not exist (any more).
  Future<bool> copy({
    required String sourceId,
    required String attachmentId,
    required String messageId,
  });

  /// Load bytes for a single image. Returns `null` if the attachment has
  /// been deleted (e.g. its owning message was removed) or holds photo
  /// metadata, which is never drawn.
  Future<Uint8List?> loadBytes(String attachmentId);

  /// Bulk-load bytes for a set of image ids, used by the chat pipeline
  /// right before serialising an API request. Missing ids — and photo
  /// metadata, which never goes to the model — are silently omitted from
  /// the result rather than throwing; callers already handle partial
  /// resolution.
  Future<ImageBytesMap> loadMany(Iterable<String> attachmentIds);

  /// The photo metadata stored under [attachmentId], or `null` when there
  /// is no such attachment.
  Future<PhotoMetadataBlocks?> loadPhotoMetadata(String attachmentId);
}
