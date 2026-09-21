import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/chat_session.dart';
import 'package:specterchat/application/llm_hooks/llm_hook_registry.dart';
import 'package:specterchat/application/llm_hooks/qwen3.dart';
import 'package:specterchat/domain/chat_session_state.dart';
import 'package:specterchat/domain/models/conversation.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/domain/models/request_profile.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/domain/services/i_mcp_service.dart';
import 'package:specterchat/domain/services/llm_hook.dart';

import '../../support/fakes.dart';

const _conv = 'conv-1';

const _toolCall = [
  ToolCallDelta(index: 0, id: 'tc-1', name: 'search', argumentsDelta: '{"q":'),
  ToolCallDelta(index: 0, argumentsDelta: '"dart"}'),
];

void main() {
  late InMemoryMessageRepository messages;
  late InMemoryConversationRepository conversations;
  late FakeMcpService mcp;

  setUp(() async {
    messages = InMemoryMessageRepository();
    conversations = InMemoryConversationRepository();
    mcp = FakeMcpService({
      'search': (_) => McpToolResult(content: [McpTextContent('found it')]),
    });
    conversations.rows[_conv] = Conversation(
      id: _conv,
      title: kDefaultConversationTitle,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );
  });

  ChatSession session(
    FakeLlmService llm, {
    LlmHookRegistry hooks = const LlmHookRegistry.none(),
    String modelName = 'fake-model',
    RequestProfile profile = const TextRequestProfile(),
    InMemoryAttachmentRepository? attachments,
  }) => ChatSession(
    conversationId: _conv,
    persistenceThrottle: const Duration(milliseconds: 5),
    resolveDeps: () => depsWith(
      llm: llm,
      messages: messages,
      conversations: conversations,
      attachments: attachments,
      mcpService: mcp,
      activeServers: [
        activeServer(tools: [tool('search')]),
      ],
      hooks: hooks,
      modelName: modelName,
      profile: profile,
    ),
  );

  List<Message> persisted() => messages.messagesFor(_conv);

  group('happy path', () {
    test(
      'persists the user message, streams the reply and finalises it',
      () async {
        final llm = FakeLlmService.events([
          [
            const ThinkingDelta('hmm'),
            const ContentDelta('Hello'),
            const ContentDelta(' world'),
            const StreamUsage(promptTokens: 40, completionTokens: 2),
            const StreamDone(),
          ],
        ]);
        final s = session(llm);

        final states = <ChatSessionState>[];
        s.state.addListener(() => states.add(s.state.value));

        await s.sendMessage('hi');

        final rows = persisted();
        expect(rows.map((m) => m.role), [
          MessageRole.user,
          MessageRole.assistant,
        ]);
        final reply = rows.last;
        expect(reply.isStreaming, isFalse);
        expect(reply.content, [
          const ContentBlock.thinking(text: 'hmm'),
          const ContentBlock.text(text: 'Hello world'),
        ]);
        expect(reply.completionTokens, 2);
        expect(s.state.value, isA<SessionIdle>());
        expect(s.state.value.promptTokens, 40);
        expect(states.whereType<SessionStreaming>(), isNotEmpty);
        // Only user + system prompt went to the model on the first turn.
        expect(llm.receivedHistories.single.map((m) => m.role), [
          MessageRole.user,
        ]);
        expect(llm.receivedTools.single.map((t) => t.name), ['search']);
      },
    );

    test("the deps snapshot's request profile reaches the LLM", () async {
      const profile = ImageRequestProfile(image: ImageSettings(steps: 7));
      final llm = FakeLlmService.events([
        [const ContentDelta('ok'), const StreamDone()],
      ]);
      await session(llm, profile: profile).sendMessage('draw');
      expect(llm.receivedProfiles.single, same(profile));
    });

    test('auto-titles a fresh conversation from the first reply', () async {
      final s = session(
        FakeLlmService.events([
          [const ContentDelta('Dart is great\nMore text'), const StreamDone()],
        ]),
      );
      await s.sendMessage('tell me');
      expect(conversations.rows[_conv]!.title, 'Dart is great');
    });

    test('persists prompt tokens on the conversation for the gauge', () async {
      final s = session(
        FakeLlmService.events([
          [
            const ContentDelta('x'),
            const StreamUsage(promptTokens: 123, completionTokens: 1),
            const StreamDone(),
          ],
        ]),
      );
      await s.sendMessage('hi');
      expect(conversations.rows[_conv]!.lastPromptTokens, 123);
    });

    test('hydrate restores prompt tokens without streaming', () async {
      final s = session(FakeLlmService.events(const []));
      s.hydrate(conversations.rows[_conv]!.copyWith(lastPromptTokens: 77));
      expect(s.state.value, isA<SessionIdle>());
      expect(s.state.value.promptTokens, 77);
    });
  });

  group('tool loop', () {
    test('runs the tool, saves the result and asks the model again', () async {
      final llm = FakeLlmService.events([
        [..._toolCall, const StreamDone()],
        [const ContentDelta('Answer'), const StreamDone()],
      ]);
      final s = session(llm);

      await s.sendMessage('search dart');

      expect(mcp.calls, hasLength(1));
      final (server, toolName, args) = mcp.calls.single;
      expect(server, 'srv');
      expect(toolName, 'search');
      expect(args, {'q': 'dart'});
      expect(persisted().map((m) => m.role), [
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.tool,
        MessageRole.assistant,
      ]);
      // Second request carries the full history including the tool result.
      expect(llm.receivedHistories[1].map((m) => m.role), [
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.tool,
      ]);
      expect(persisted().last.content, [
        const ContentBlock.text(text: 'Answer'),
      ]);
    });
  });

  group('stop', () {
    test('keeps partial text and does NOT run a pending tool call', () async {
      // The model emits a complete tool call, then stalls. The user presses
      // stop while the stream is still open.
      final stalled = Completer<void>();
      final llm = FakeLlmService([
        (token) async* {
          yield const ContentDelta('Let me search');
          yield* Stream.fromIterable(_toolCall);
          await stalled.future;
          // What a real transport does once its cancel token fires.
          yield const StreamCancelled();
        },
      ]);
      final s = session(llm);

      final send = s.sendMessage('search dart');
      // Let the stream deliver its first events.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(s.isGenerating, isTrue);

      final stop = s.stop();
      stalled.complete();
      await stop;
      await send;

      expect(s.state.value, isA<SessionIdle>());
      expect(mcp.calls, isEmpty, reason: 'stop must not execute tools');
      expect(llm.calls, 1, reason: 'no continuation request after stop');
      final reply = persisted().last;
      expect(reply.role, MessageRole.assistant);
      expect(reply.isStreaming, isFalse);
      expect(
        reply.content.whereType<TextContentBlock>().single.text,
        'Let me search',
      );
    });

    test(
      'drops the placeholder when nothing arrived before the stop',
      () async {
        final stalled = Completer<void>();
        final llm = FakeLlmService([
          (token) async* {
            await stalled.future;
            yield const StreamCancelled();
          },
        ]);
        final s = session(llm);

        final send = s.sendMessage('hi');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Placeholder row exists while streaming.
        expect(persisted().map((m) => m.role), [
          MessageRole.user,
          MessageRole.assistant,
        ]);

        final stop = s.stop();
        stalled.complete();
        await stop;
        await send;

        expect(persisted().map((m) => m.role), [MessageRole.user]);
        expect(s.state.value, isA<SessionIdle>());
      },
    );

    test('a cancel that lands after StreamDone skips the tool round', () async {
      // The token is cancelled as soon as the model finishes its turn —
      // before the tool executor would have run.
      late final ChatSession s;
      final llm = FakeLlmService([
        (token) async* {
          yield* Stream.fromIterable(_toolCall);
          token!.cancel();
          yield const StreamDone();
        },
      ]);
      s = session(llm);
      await s.sendMessage('search');
      expect(mcp.calls, isEmpty);
      expect(llm.calls, 1);
    });

    test('stop is a no-op when idle', () async {
      final s = session(FakeLlmService.events(const []));
      await s.stop();
      expect(s.state.value, isA<SessionIdle>());
    });
  });

  group('errors', () {
    test(
      'transport error keeps partial text and surfaces SessionError',
      () async {
        final s = session(
          FakeLlmService.events([
            [const ContentDelta('partial'), const StreamError('boom')],
          ]),
        );
        await s.sendMessage('hi');
        expect(s.state.value, isA<SessionError>());
        expect((s.state.value as SessionError).message, 'boom');
        expect(persisted().last.isStreaming, isFalse);
        expect(
          persisted().last.content.whereType<TextContentBlock>().single.text,
          'partial',
        );

        s.clearError();
        expect(s.state.value, isA<SessionIdle>());
      },
    );

    test('an exception in the pipeline becomes SessionError', () async {
      final s = session(
        FakeLlmService([(_) => Stream.error(StateError('kaboom'))]),
      );
      await s.sendMessage('hi');
      expect(s.state.value, isA<SessionError>());
    });

    test('sendMessage while streaming is ignored', () async {
      final gate = Completer<void>();
      final llm = FakeLlmService([
        (_) async* {
          await gate.future;
          yield const StreamDone();
        },
      ]);
      final s = session(llm);
      final first = s.sendMessage('one');
      await Future<void>.delayed(Duration.zero);
      await s.sendMessage('two');
      gate.complete();
      await first;
      expect(persisted().where((m) => m.role == MessageRole.user).length, 1);
    });
  });

  group('hallucination recovery', () {
    const qwen = LlmHookRegistry([Qwen3Hook()], maxHallucinationRetries: 1);

    test(
      'XML tool call is discarded, a correction is sent, then retried',
      () async {
        final llm = FakeLlmService.events([
          [
            const ContentDelta('<tool_call>search</tool_call>'),
            const StreamDone(),
          ],
          [const ContentDelta('Proper answer'), const StreamDone()],
        ]);
        final s = session(llm, hooks: qwen, modelName: 'qwen3.5-27b');

        await s.sendMessage('search');

        final rows = persisted();
        expect(rows.map((m) => m.role), [
          MessageRole.user,
          MessageRole.user, // correction
          MessageRole.assistant,
        ]);
        expect(rows[1].plainText, startsWith(correctionPrefix));
        expect(rows.last.plainText, 'Proper answer');
        expect(llm.calls, 2);
      },
    );

    test('gives up after maxHallucinationRetries', () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('<tool_call>a</tool_call>'), const StreamDone()],
        [const ContentDelta('<tool_call>b</tool_call>'), const StreamDone()],
      ]);
      final s = session(llm, hooks: qwen, modelName: 'qwen3.5');
      await s.sendMessage('go');
      expect(llm.calls, 2);
      expect(
        persisted().where((m) => m.role == MessageRole.assistant),
        isEmpty,
      );
      expect(s.state.value, isA<SessionIdle>());
    });

    test('models without a hook are never corrected', () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('<tool_call>x</tool_call>'), const StreamDone()],
      ]);
      final s = session(llm, hooks: qwen, modelName: 'llama-3');
      await s.sendMessage('go');
      expect(llm.calls, 1);
      expect(persisted().last.plainText, '<tool_call>x</tool_call>');
    });
  });

  group('images', () {
    final pngBytes = fakePngBytes();
    late InMemoryAttachmentRepository attachments;

    ChatSession imageSession(FakeLlmService llm) =>
        session(llm, attachments: attachments);

    setUp(() => attachments = InMemoryAttachmentRepository());

    test('attached images become image blocks backed by attachments', () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('nice'), const StreamDone()],
      ]);
      final s = imageSession(llm);

      await s.sendMessage(
        'look',
        images: [
          OutgoingImage(bytes: pngBytes, mimeType: 'image/png'),
          OutgoingImage(bytes: pngBytes, mimeType: 'image/jpeg'),
        ],
      );

      final user = persisted().first;
      expect(user.role, MessageRole.user);
      expect(user.content.first, const ContentBlock.text(text: 'look'));
      final blocks = user.content.whereType<ImageContentBlock>().toList();
      expect(blocks.map((b) => b.mimeType), ['image/png', 'image/jpeg']);
      expect(blocks.map((b) => b.byteSize), [pngBytes.length, pngBytes.length]);
      for (final b in blocks) {
        expect(attachments.rows[b.attachmentId]?.bytes, pngBytes);
      }
      // The write was transactional: message + blobs together.
      expect(messages.calls.first, 'save:user');
    });

    test(
      'image-only send has no text block and still reaches the model',
      () async {
        final llm = FakeLlmService.events([
          [const ContentDelta('ok'), const StreamDone()],
        ]);
        final s = imageSession(llm);
        await s.sendMessage(
          '',
          images: [OutgoingImage(bytes: pngBytes, mimeType: 'image/png')],
        );

        final user = persisted().first;
        expect(user.content.whereType<TextContentBlock>(), isEmpty);
        expect(user.content.whereType<ImageContentBlock>(), hasLength(1));
        expect(llm.receivedHistories.single.single.id, user.id);
      },
    );

    test('empty text with no images is a no-op', () async {
      final llm = FakeLlmService.events([]);
      final s = imageSession(llm);
      await s.sendMessage('   ');
      expect(persisted(), isEmpty);
      expect(llm.calls, 0);
    });

    test('a streamed image is stored and persisted on the reply', () async {
      final llm = FakeLlmService.events([
        [
          const ContentDelta('Here you go'),
          ImageDelta(bytes: pngBytes, mimeType: 'image/png'),
          const StreamDone(),
        ],
      ]);
      final s = imageSession(llm);
      await s.sendMessage('draw a cat');

      final reply = persisted().last;
      expect(reply.role, MessageRole.assistant);
      expect(reply.isStreaming, isFalse);
      expect(reply.content.first, const ContentBlock.text(text: 'Here you go'));
      final img = reply.content.whereType<ImageContentBlock>().single;
      expect(img.mimeType, 'image/png');
      expect(img.byteSize, pngBytes.length);
      expect(attachments.rows[img.attachmentId]?.bytes, pngBytes);
    });

    test('an image-only reply is kept (not discarded as empty)', () async {
      final llm = FakeLlmService.events([
        [
          ImageDelta(bytes: pngBytes, mimeType: 'image/png'),
          const StreamDone(),
        ],
      ]);
      final s = imageSession(llm);
      await s.sendMessage('draw');
      final reply = persisted().last;
      expect(reply.role, MessageRole.assistant);
      expect(reply.content.whereType<ImageContentBlock>(), hasLength(1));
      expect(messages.calls, isNot(contains('delete')));
    });

    test(
      'progress is mirrored into the streaming state and cleared after',
      () async {
        final llm = FakeLlmService.events([
          [
            const ProgressDelta(GenerationProgress(stage: 'loading')),
            const ProgressDelta(
              GenerationProgress(
                stage: 'generating',
                step: 12,
                total: 40,
                message: 'Génération 12/40',
              ),
            ),
            const StreamUsage(promptTokens: 10, completionTokens: 0),
            const StreamDone(),
          ],
        ]);
        final s = imageSession(llm);
        final seen = <GenerationProgress?>[];
        s.state.addListener(() {
          if (s.state.value case SessionStreaming(:final progress)) {
            seen.add(progress);
          }
        });

        await s.sendMessage('draw');

        final labels = seen.whereType<GenerationProgress>().map((p) => p.label);
        expect(labels, containsAllInOrder(['loading', 'Génération 12/40']));
        // Usage arriving after progress must not wipe it.
        expect(seen.last?.step, 12);
        expect(seen.last?.fraction, closeTo(0.3, 1e-9));
        expect(s.state.value, isA<SessionIdle>());
      },
    );

    test('stop after an image keeps the image', () async {
      final stalled = Completer<void>();
      final llm = FakeLlmService([
        (token) async* {
          yield ImageDelta(bytes: pngBytes, mimeType: 'image/png');
          await stalled.future;
          yield const StreamCancelled();
        },
      ]);
      final s = imageSession(llm);
      final send = s.sendMessage('draw');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stop = s.stop();
      stalled.complete();
      await stop;
      await send;

      final reply = persisted().last;
      expect(reply.role, MessageRole.assistant);
      expect(reply.isStreaming, isFalse);
      expect(reply.content.whereType<ImageContentBlock>(), hasLength(1));
    });

    test('the generated image is re-sent on the next turn', () async {
      final llm = FakeLlmService.events([
        [
          ImageDelta(bytes: pngBytes, mimeType: 'image/png'),
          const StreamDone(),
        ],
        [const ContentDelta('done'), const StreamDone()],
      ]);
      final s = imageSession(llm);
      await s.sendMessage('draw');
      await s.sendMessage('make it blue');

      final history = llm.receivedHistories.last;
      expect(history.map((m) => m.role), [
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.user,
      ]);
      expect(history[1].imageAttachmentIds(), hasLength(1));
    });
  });

  group('photo metadata', () {
    final pngBytes = fakePngBytes();
    late InMemoryAttachmentRepository attachments;

    ChatSession imageSession(FakeLlmService llm) =>
        session(llm, attachments: attachments);

    setUp(() => attachments = InMemoryAttachmentRepository());

    const photo = PhotoMetadata(
      camera: CameraInfo(make: 'Apple', model: 'iPhone 17'),
      location: GeoLocation(latitude: 42.56858, longitude: 8.75145),
    );

    ImageContentBlock lastImage() =>
        persisted().last.content.whereType<ImageContentBlock>().single;

    test('an attached photo keeps its metadata on its image block', () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('nice'), const StreamDone()],
      ]);
      await imageSession(llm).sendMessage(
        'look',
        images: [
          OutgoingImage(
            bytes: pngBytes,
            mimeType: 'image/png',
            metadata: photo,
          ),
          OutgoingImage(bytes: pngBytes, mimeType: 'image/png'),
        ],
      );

      final blocks = persisted().first.content.whereType<ImageContentBlock>();
      expect(blocks.map((b) => b.photoMetadata), [photo, null]);
    });

    test('an edit of the photo inherits its metadata', () async {
      final llm = FakeLlmService.events([
        [
          ImageDelta(bytes: pngBytes, mimeType: 'image/png'),
          const StreamDone(),
        ],
      ]);
      await imageSession(llm).sendMessage(
        'make the sky orange',
        images: [
          OutgoingImage(
            bytes: pngBytes,
            mimeType: 'image/png',
            metadata: photo,
          ),
        ],
      );

      expect(lastImage().photoMetadata, photo);
    });

    test('an image generated from the prompt alone inherits nothing', () async {
      final llm = FakeLlmService.events([
        [
          ImageDelta(bytes: pngBytes, mimeType: 'image/png', textToImage: true),
          const StreamDone(),
        ],
      ]);
      await imageSession(llm).sendMessage(
        'a cat instead',
        images: [
          OutgoingImage(
            bytes: pngBytes,
            mimeType: 'image/png',
            metadata: photo,
          ),
        ],
      );

      expect(lastImage().photoMetadata, isNull);
    });

    test('the metadata follows a chain of edits', () async {
      final edit = [
        ImageDelta(bytes: pngBytes, mimeType: 'image/png'),
        const StreamDone(),
      ];
      final llm = FakeLlmService.events([edit, edit, edit]);
      final s = imageSession(llm);
      await s.sendMessage(
        'make it blue',
        images: [
          OutgoingImage(
            bytes: pngBytes,
            mimeType: 'image/png',
            metadata: photo,
          ),
        ],
      );
      // No image attached: the server edits its latest output, and so the
      // new image inherits from it — twice.
      await s.sendMessage('add a hat');
      await s.sendMessage('now at night');

      final generated = persisted()
          .where((m) => m.role == MessageRole.assistant)
          .map((m) => m.content.whereType<ImageContentBlock>().single);
      expect(generated.map((b) => b.photoMetadata), [photo, photo, photo]);
    });

    test('a fresh attachment without metadata breaks the chain', () async {
      final edit = [
        ImageDelta(bytes: pngBytes, mimeType: 'image/png'),
        const StreamDone(),
      ];
      final llm = FakeLlmService.events([edit, edit]);
      final s = imageSession(llm);
      await s.sendMessage(
        'make it blue',
        images: [
          OutgoingImage(
            bytes: pngBytes,
            mimeType: 'image/png',
            metadata: photo,
          ),
        ],
      );
      await s.sendMessage(
        'use this one instead',
        images: [OutgoingImage(bytes: pngBytes, mimeType: 'image/png')],
      );

      expect(lastImage().photoMetadata, isNull);
    });
  });

  group('dispose', () {
    test('cancels an in-flight stream and settles', () async {
      final stalled = Completer<void>();
      final llm = FakeLlmService([
        (token) async* {
          yield const ContentDelta('a');
          await token!.whenCancelled;
          yield const StreamCancelled();
        },
      ]);
      final s = session(llm);
      final send = s.sendMessage('hi');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await s.dispose();
      await send;
      stalled.complete();
      expect(persisted().last.isStreaming, isFalse);
      // Further sends are ignored.
      await s.sendMessage('again');
      expect(llm.calls, 1);
    });
  });
}
