import 'dart:typed_data';

import '../models/message.dart' show ImageBytesMap;

/// Persistence contract for binary attachments (images).
///
/// Attachments live in their own table so [Message.content] JSON can
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

  /// Decode [base64Data] and persist. Convenience for MCP-produced
  /// images which arrive as base64 strings.
  Future<String> storeBase64({
    String? attachmentId,
    required String messageId,
    required String base64Data,
    required String mimeType,
  });

  /// Load bytes for a single attachment. Returns `null` if the
  /// attachment has been deleted (e.g. its owning message was removed).
  Future<Uint8List?> loadBytes(String attachmentId);

  /// Bulk-load bytes for a set of attachment ids, used by the chat
  /// pipeline right before serialising an API request. Missing ids are
  /// silently omitted from the result rather than throwing — callers
  /// already handle partial resolution.
  Future<ImageBytesMap> loadMany(Iterable<String> attachmentIds);

  /// Remove every attachment owned by [messageId]. Used when a streaming
  /// placeholder is dropped before any real content committed. FK cascade
  /// handles the normal delete-conversation/message path automatically.
  Future<void> deleteForMessage(String messageId);
}
