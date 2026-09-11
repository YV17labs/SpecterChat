import 'dart:typed_data';

import '../../core/id_gen.dart';
import '../../domain/models/message.dart' show ImageBytes, ImageBytesMap;
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
  Future<Uint8List?> loadBytes(String attachmentId) async {
    final row = await (_db.select(
      _db.attachments,
    )..where((t) => t.id.equals(attachmentId))).getSingleOrNull();
    return row?.data;
  }

  @override
  Future<ImageBytesMap> loadMany(Iterable<String> attachmentIds) async {
    final ids = attachmentIds.toSet();
    if (ids.isEmpty) return const <String, ImageBytes>{};
    final rows = await (_db.select(
      _db.attachments,
    )..where((t) => t.id.isIn(ids))).get();
    return {for (final r in rows) r.id: (bytes: r.data, mimeType: r.mimeType)};
  }
}
