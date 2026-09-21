import 'dart:typed_data';

import '../../domain/models/message.dart';
import '../../domain/models/photo_metadata.dart';
import '../../domain/repositories/i_attachment_repository.dart';
import '../../domain/repositories/i_message_repository.dart';

/// A blob an image block of a message refers to, not yet stored.
class PendingAttachment {
  final String attachmentId;
  final Uint8List bytes;
  final String mimeType;

  /// Stored on the image block that references the blob.
  final PhotoMetadata? metadata;

  const PendingAttachment({
    required this.attachmentId,
    required this.bytes,
    required this.mimeType,
    this.metadata,
  });
}

/// A message row together with the blobs its image blocks reference.
class MessageWrite {
  final Message message;
  final List<PendingAttachment> attachments;

  const MessageWrite(this.message, {this.attachments = const []});
}

/// Writes rows and blobs in one transaction. Without it the `messages`
/// watcher emits between the two inserts and the UI gets stuck on "Image
/// unavailable" for an attachment id whose row has not landed yet. Every
/// path that stores a message with images goes through here.
Future<void> saveMessagesWithAttachments(
  IMessageRepository messages,
  IAttachmentRepository attachments,
  Iterable<MessageWrite> writes,
) => messages.runInTransaction(() async {
  for (final write in writes) {
    await messages.saveMessage(write.message);
    for (final pending in write.attachments) {
      await attachments.storeBytes(
        attachmentId: pending.attachmentId,
        messageId: write.message.id,
        bytes: pending.bytes,
        mimeType: pending.mimeType,
      );
    }
  }
});
