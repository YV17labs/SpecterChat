import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/infrastructure/persistence/attachment_repository.dart';
import 'package:specterchat/infrastructure/persistence/conversation_repository.dart';
import 'package:specterchat/infrastructure/persistence/database.dart' as db;
import 'package:specterchat/infrastructure/persistence/message_repository.dart';

import '../../support/fakes.dart';

void main() {
  late db.AppDatabase database;
  late AttachmentRepository repo;
  late String convId;
  const msgId = 'msg-1';

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    repo = AttachmentRepository(database);
    // Attachments hang off a message row; seed one through the repositories.
    convId = await ConversationRepository(database).createConversation();
    await MessageRepository(database).saveMessage(
      testMessage(
        MessageRole.tool,
        const [],
        id: msgId,
        conversationId: convId,
      ),
    );
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

  test(
    'FK cascade deletes attachments when owning message is removed',
    () async {
      final id = await repo.storeBytes(
        messageId: msgId,
        bytes: Uint8List.fromList([1]),
        mimeType: 'image/png',
      );
      await (database.delete(
        database.messages,
      )..where((t) => t.id.equals(msgId))).go();
      expect(await repo.loadBytes(id), isNull);
    },
  );

  group('photo metadata', () {
    const blocks = kPhotoBlocks;
    Future<void> storeMetadata(String id, String messageId) =>
        storePhotoMetadata(repo, id, messageId: messageId);
    Future<void> message(String id) => MessageRepository(database).saveMessage(
      testMessage(
        MessageRole.assistant,
        const [],
        id: id,
        conversationId: convId,
      ),
    );
    Future<void> delete(String messageId) =>
        MessageRepository(database).deleteMessage(messageId);

    test('is loaded as such, never as an image', () async {
      await storeMetadata('meta', msgId);
      await repo.storeBytes(
        attachmentId: 'img',
        messageId: msgId,
        bytes: Uint8List.fromList([1]),
        mimeType: 'image/png',
      );

      expect(await repo.loadPhotoMetadata('meta'), blocks);
      expect(await repo.loadPhotoMetadata('img'), isNull);
      expect(await repo.loadPhotoMetadata('nope'), isNull);
      expect(await repo.loadBytes('meta'), isNull);
      expect((await repo.loadMany(['img', 'meta'])).keys, ['img']);
    });

    test('a copy lives and dies with its own message', () async {
      await storeMetadata('meta', msgId);
      await message('reply');
      expect(
        await repo.copy(
          sourceId: 'meta',
          attachmentId: 'copy',
          messageId: 'reply',
        ),
        isTrue,
      );
      expect(await repo.loadPhotoMetadata('copy'), blocks);

      // The source's message goes: the copy stays.
      await delete(msgId);
      expect(await repo.loadPhotoMetadata('meta'), isNull);
      expect(await repo.loadPhotoMetadata('copy'), blocks);

      // Its own message goes (a discarded placeholder): so does the copy.
      await delete('reply');
      expect(await repo.loadPhotoMetadata('copy'), isNull);
    });

    test('copying what is gone copies nothing', () async {
      expect(
        await repo.copy(
          sourceId: 'nope',
          attachmentId: 'copy',
          messageId: msgId,
        ),
        isFalse,
      );
      expect(await repo.loadPhotoMetadata('copy'), isNull);
    });
  });
}
