import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/database/attachment_repository.dart';
import 'package:specterchat/database/database.dart' as db;

void main() {
  late db.AppDatabase database;
  late AttachmentRepository repo;
  const convId = 'conv-1';
  const msgId = 'msg-1';

  Future<void> seedMessage() async {
    await database.insertConversation(db.ConversationsCompanion.insert(
      id: convId,
      title: 'Chat',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
    await database.insertMessage(db.MessagesCompanion.insert(
      id: msgId,
      conversationId: convId,
      role: 'tool',
      content: '[]',
      createdAt: DateTime.now(),
      isStreaming: const Value(false),
    ));
  }

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    repo = AttachmentRepository(database);
    await seedMessage();
  });

  tearDown(() async {
    await database.close();
  });

  test('storeBytes with generated id round-trips bytes', () async {
    final id = await repo.storeBytes(
      messageId: msgId,
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      mimeType: 'image/png',
    );
    expect(id, isNotEmpty);
    final loaded = await repo.loadBytes(id);
    expect(loaded, Uint8List.fromList([1, 2, 3, 4]));
  });

  test('storeBytes with caller-provided id uses that id', () async {
    await repo.storeBytes(
      attachmentId: 'att-fixed',
      messageId: msgId,
      bytes: Uint8List.fromList([9, 9]),
      mimeType: 'image/jpeg',
    );
    final loaded = await repo.loadBytes('att-fixed');
    expect(loaded, Uint8List.fromList([9, 9]));
  });

  test('storeBase64 decodes then persists', () async {
    final raw = Uint8List.fromList([10, 20, 30]);
    final id = await repo.storeBase64(
      messageId: msgId,
      base64Data: base64Encode(raw),
      mimeType: 'image/png',
    );
    final loaded = await repo.loadBytes(id);
    expect(loaded, raw);
  });

  test('loadMany returns only existing ids', () async {
    await repo.storeBytes(
      attachmentId: 'att-a',
      messageId: msgId,
      bytes: Uint8List.fromList([1]),
      mimeType: 'image/png',
    );
    await repo.storeBytes(
      attachmentId: 'att-b',
      messageId: msgId,
      bytes: Uint8List.fromList([2]),
      mimeType: 'image/jpeg',
    );
    final loaded = await repo.loadMany(['att-a', 'att-b', 'missing']);
    expect(loaded.keys, unorderedEquals(['att-a', 'att-b']));
    expect(loaded['att-a']!.mimeType, 'image/png');
  });

  test('loadBytes returns null for unknown id', () async {
    expect(await repo.loadBytes('nope'), isNull);
  });

  test('deleteForMessage removes every attachment for that message', () async {
    await repo.storeBytes(
      messageId: msgId,
      bytes: Uint8List.fromList([1]),
      mimeType: 'image/png',
    );
    await repo.storeBytes(
      messageId: msgId,
      bytes: Uint8List.fromList([2]),
      mimeType: 'image/png',
    );
    await repo.deleteForMessage(msgId);
    final remaining = await repo.loadMany(const ['any']);
    expect(remaining, isEmpty);
  });

  test('FK cascade deletes attachments when owning message is removed',
      () async {
    final id = await repo.storeBytes(
      messageId: msgId,
      bytes: Uint8List.fromList([1]),
      mimeType: 'image/png',
    );
    await database.deleteMessage(msgId);
    expect(await repo.loadBytes(id), isNull);
  });
}
