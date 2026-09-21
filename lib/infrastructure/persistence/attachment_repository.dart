import 'package:drift/drift.dart';

import '../../core/id_gen.dart';
import '../../domain/models/message.dart' show ImageBytes, ImageBytesMap;
import '../../domain/models/photo_metadata.dart' show PhotoMetadataBlocks;
import '../../domain/repositories/i_attachment_repository.dart';
import 'database.dart';

/// Drift-backed implementation of [IAttachmentRepository].
class AttachmentRepository implements IAttachmentRepository {
  final AppDatabase _db;

  AttachmentRepository(this._db);

  @override
  Future<String> storeBytes({
    String? attachmentId,
    required String messageId,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final id = attachmentId ?? generateId();
    await _db
        .into(_db.attachments)
        .insert(
          AttachmentsCompanion.insert(
            id: id,
            messageId: messageId,
            mimeType: mimeType,
            data: bytes,
            byteSize: bytes.length,
            createdAt: DateTime.now(),
          ),
        );
    return id;
  }

  @override
  Future<bool> copy({
    required String sourceId,
    required String attachmentId,
    required String messageId,
  }) async {
    // In SQLite: the bytes never cross into Dart.
    final copied = await _db.customUpdate(
      'INSERT INTO attachments '
      '(id, message_id, mime_type, data, byte_size, created_at) '
      'SELECT ?, ?, mime_type, data, byte_size, ? FROM attachments '
      'WHERE id = ?',
      variables: [
        Variable.withString(attachmentId),
        Variable.withString(messageId),
        Variable.withDateTime(DateTime.now()),
        Variable.withString(sourceId),
      ],
      updates: {_db.attachments},
      updateKind: UpdateKind.insert,
    );
    return copied > 0;
  }

  @override
  Future<Uint8List?> loadBytes(String attachmentId) async {
    final row = await (_db.select(
      _db.attachments,
    )..where((t) => t.id.equals(attachmentId) & _isImage(t))).getSingleOrNull();
    return row?.data;
  }

  @override
  Future<ImageBytesMap> loadMany(Iterable<String> attachmentIds) async {
    final ids = attachmentIds.toSet();
    if (ids.isEmpty) return const <String, ImageBytes>{};
    final rows = await (_db.select(
      _db.attachments,
    )..where((t) => t.id.isIn(ids) & _isImage(t))).get();
    return {for (final r in rows) r.id: (bytes: r.data, mimeType: r.mimeType)};
  }

  @override
  Future<PhotoMetadataBlocks?> loadPhotoMetadata(String attachmentId) async {
    final row =
        await (_db.select(_db.attachments)..where(
              (t) =>
                  t.id.equals(attachmentId) &
                  t.mimeType.equals(PhotoMetadataBlocks.mimeType),
            ))
            .getSingleOrNull();
    return row == null ? null : PhotoMetadataBlocks.decode(row.data);
  }

  /// Anything but photo metadata: images are whatever MIME type the model
  /// or the MCP server gave them.
  static Expression<bool> _isImage(Attachments t) =>
      t.mimeType.equals(PhotoMetadataBlocks.mimeType).not();
}
