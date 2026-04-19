import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/database/conversation_repository.dart';
import 'package:specterchat/database/database.dart' hide Message;
import 'package:specterchat/models/message.dart';

void main() {
  late AppDatabase db;
  late ConversationRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ConversationRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('ConversationRepository', () {
    group('conversations', () {
      test('createConversation returns an id', () async {
        final id = await repo.createConversation();
        expect(id, isNotEmpty);
      });

      test('createConversation with systemPrompt', () async {
        final id = await repo.createConversation(
          systemPrompt: 'Be concise',
        );
        // Verify via watchAllConversations
        final convs =
            await repo.watchAllConversations().first;
        final conv = convs.firstWhere((c) => c.id == id);
        expect(conv.systemPrompt, 'Be concise');
        expect(conv.title, 'New Chat');
      });

      test('watchAllConversations returns created conversations', () async {
        await repo.createConversation();
        await repo.createConversation();

        final convs =
            await repo.watchAllConversations().first;
        expect(convs.length, 2);
      });

      test('renameConversation updates title', () async {
        final id = await repo.createConversation();
        await repo.renameConversation(id, 'My Chat');

        final convs =
            await repo.watchAllConversations().first;
        expect(convs.first.title, 'My Chat');
      });

      test('deleteConversation removes it', () async {
        final id = await repo.createConversation();
        await repo.deleteConversation(id);

        final convs =
            await repo.watchAllConversations().first;
        expect(convs, isEmpty);
      });

      test('deleteConversation also removes messages', () async {
        final id = await repo.createConversation();
        await repo.saveMessage(Message(
          id: 'msg-1',
          conversationId: id,
          role: MessageRole.user,
          content: [const ContentBlock.text(text: 'hello')],
          createdAt: DateTime.now(),
        ));

        await repo.deleteConversation(id);

        final msgs = await repo.getMessages(id);
        expect(msgs, isEmpty);
      });
    });

    group('messages', () {
      late String convId;

      setUp(() async {
        convId = await repo.createConversation();
      });

      test('saveMessage and getMessages roundtrip', () async {
        final msg = Message(
          id: 'msg-1',
          conversationId: convId,
          role: MessageRole.user,
          content: [const ContentBlock.text(text: 'hello')],
          createdAt: DateTime.now(),
        );
        await repo.saveMessage(msg);

        final messages = await repo.getMessages(convId);
        expect(messages.length, 1);
        expect(messages.first.id, 'msg-1');
        expect(messages.first.role, MessageRole.user);
        expect(messages.first.content.length, 1);
        expect(
          (messages.first.content.first as TextContentBlock).text,
          'hello',
        );
      });

      test('saveMessage with complex content blocks', () async {
        final msg = Message(
          id: 'msg-1',
          conversationId: convId,
          role: MessageRole.assistant,
          content: [
            const ContentBlock.thinking(text: 'thinking...'),
            const ContentBlock.text(text: 'answer'),
            const ContentBlock.toolCall(
              id: 'tc-1',
              name: 'search',
              arguments: '{"q":"test"}',
            ),
          ],
          createdAt: DateTime.now(),
        );
        await repo.saveMessage(msg);

        final messages = await repo.getMessages(convId);
        expect(messages.first.content.length, 3);
        expect(messages.first.content[0], isA<ThinkingContentBlock>());
        expect(messages.first.content[1], isA<TextContentBlock>());
        expect(messages.first.content[2], isA<ToolCallContentBlock>());
      });

      test('saveMessage with tool result and image', () async {
        final msg = Message(
          id: 'msg-1',
          conversationId: convId,
          role: MessageRole.tool,
          content: [
            const ContentBlock.toolResult(
              toolCallId: 'tc-1',
              toolName: 'screenshot',
              resultContent: [
                ContentBlock.text(text: 'captured'),
                ContentBlock.image(
                  base64Data: 'imgdata',
                  mimeType: 'image/png',
                ),
              ],
            ),
          ],
          createdAt: DateTime.now(),
        );
        await repo.saveMessage(msg);

        final messages = await repo.getMessages(convId);
        final block =
            messages.first.content.first as ToolResultContentBlock;
        final image =
            block.resultContent.whereType<ImageContentBlock>().single;
        expect(image.base64Data, 'imgdata');
        expect(image.mimeType, 'image/png');
      });

      test('updateMessage changes content', () async {
        await repo.saveMessage(Message(
          id: 'msg-1',
          conversationId: convId,
          role: MessageRole.user,
          content: [const ContentBlock.text(text: 'old')],
          createdAt: DateTime.now(),
        ));

        await repo.updateMessage(Message(
          id: 'msg-1',
          conversationId: convId,
          role: MessageRole.user,
          content: [const ContentBlock.text(text: 'updated')],
          createdAt: DateTime.now(),
        ));

        final messages = await repo.getMessages(convId);
        expect(
          (messages.first.content.first as TextContentBlock).text,
          'updated',
        );
      });

      test('watchMessages emits on new messages', () async {
        final stream = repo.watchMessages(convId);

        expectLater(
          stream,
          emitsInOrder([
            hasLength(0),
            hasLength(1),
          ]),
        );

        await repo.saveMessage(Message(
          id: 'msg-1',
          conversationId: convId,
          role: MessageRole.user,
          content: [const ContentBlock.text(text: 'hi')],
          createdAt: DateTime.now(),
        ));
      });

      test('messages preserve ordering by createdAt', () async {
        await repo.saveMessage(Message(
          id: 'msg-2',
          conversationId: convId,
          role: MessageRole.assistant,
          content: [const ContentBlock.text(text: 'hi')],
          createdAt: DateTime(2024, 1, 1, 10, 5),
        ));
        await repo.saveMessage(Message(
          id: 'msg-1',
          conversationId: convId,
          role: MessageRole.user,
          content: [const ContentBlock.text(text: 'hello')],
          createdAt: DateTime(2024, 1, 1, 10, 0),
        ));

        final messages = await repo.getMessages(convId);
        expect(messages.first.id, 'msg-1');
        expect(messages.last.id, 'msg-2');
      });
    });
  });
}
