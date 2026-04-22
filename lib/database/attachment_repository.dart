import 'dart:convert';
import 'dart:typed_data';

import '../models/message.dart' show ImageBytes, ImageBytesMap;
import '../utils/id_gen.dart';
import 'database.dart' as db;
import 'i_attachment_repository.dart';

/// Drift-backed implementation of [IAttachmentRepository].
class AttachmentRepository implements IAttachmentRepository {
  final db.AppDatabase _database;

  AttachmentRepository(this._database);

  @override
  Future<String> storeBytes({
    String? attachmentId,
    required String messageId,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final id = attachmentId ?? generateId();
    await _database.insertAttachment(db.AttachmentsCompanion.insert(
      id: id,
      messageId: messageId,
      mimeType: mimeType,
      data: bytes,
      byteSize: bytes.length,
      createdAt: DateTime.now(),
    ));
    return id;
  }

  @override
  Future<String> storeBase64({
    String? attachmentId,
    required String messageId,
    required String base64Data,
    required String mimeType,
  }) {
    return storeBytes(
      attachmentId: attachmentId,
      messageId: messageId,
      bytes: base64Decode(base64Data),
      mimeType: mimeType,
    );
  }

  @override
  Future<Uint8List?> loadBytes(String attachmentId) async {
    final row = await _database.getAttachment(attachmentId);
    return row?.data;
  }

  @override
  Future<ImageBytesMap> loadMany(Iterable<String> attachmentIds) async {
    final ids = attachmentIds.toSet();
    if (ids.isEmpty) return const <String, ImageBytes>{};
    final rows = await _database.getAttachmentsByIds(ids);
    return {
      for (final r in rows)
        r.id: (bytes: r.data, mimeType: r.mimeType),
    };
  }

  @override
  Future<void> deleteForMessage(String messageId) async {
    await _database.deleteAttachmentsForMessage(messageId);
  }
}
