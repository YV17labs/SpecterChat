import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/chat_session.dart';
import 'package:specterchat/application/llm_hooks/llm_hook_registry.dart';
import 'package:specterchat/application/llm_hooks/qwen3.dart';
import 'package:specterchat/domain/chat_session_state.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/conversation.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/message_stats.dart';
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
        expect((rows.last.stats! as GenerationStats).retry, 1);
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

  test(
    'a stream that ends without a terminal event completes the turn',
    () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('cut short')],
      ]);
      final s = session(llm);
      await s.sendMessage('hi');

      final reply = persisted().last;
      expect(reply.role, MessageRole.assistant);
      expect(reply.plainText, 'cut short');
      expect(reply.isStreaming, isFalse);
      expect(s.state.value, isA<SessionIdle>());
    },
  );

  group('stats', () {
    GenerationStats statsOf(Message m) => m.stats! as GenerationStats;

    test(
      'a reply records what it was generated with and measured at',
      () async {
        const generation = GenerationSettings(temperature: 0.6, topK: 20);
        final llm = FakeLlmService.events([
          [
            const ServerReport({'id': 'chatcmpl-1', 'model': 'served-name'}),
            const ThinkingDelta('hmm'),
            const ContentDelta('Hello'),
            const StreamUsage(promptTokens: 40, completionTokens: 2),
            const ServerReport({
              'finish_reason': 'stop',
              'usage': {'prompt_tokens': 40, 'completion_tokens': 2},
            }),
            const StreamDone(),
          ],
        ]);
        await session(
          llm,
          profile: const TextRequestProfile(generation: generation),
        ).sendMessage('hi');

        final reply = persisted().last;
        final stats = statsOf(reply);
        expect(stats.model, 'fake-model');
        expect(stats.endpoint, 'http://fake.local/v1');
        expect(stats.generation, generation);
        expect(stats.image, isNull);
        // The system prompt as sent and the tool definitions, stored once.
        final context =
            conversations.requestContexts[_conv]![stats.requestContextId]!;
        expect(context.tools.map((t) => t.name), ['search']);
        expect(stats.retry, 0);
        expect(stats.outcome, GenerationOutcome.completed);
        expect(stats.promptTokens, 40);
        expect(stats.completionTokens, 2);
        expect(stats.fragments, 2);
        expect(stats.firstTokenMs, isNotNull);
        expect(stats.firstAnswerMs, greaterThanOrEqualTo(stats.firstTokenMs!));
        expect(stats.server, {
          'id': 'chatcmpl-1',
          'model': 'served-name',
          'finish_reason': 'stop',
          'usage': {'prompt_tokens': 40, 'completion_tokens': 2},
        });
        expect(stats.startedAt.isUtc, isTrue);
        // The row's own columns agree with the stats.
        expect(reply.completionTokens, 2);
        expect(reply.durationMs, stats.durationMs);
      },
    );

    test('the request context is stored once per change', () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('one'), const StreamDone()],
        [const ContentDelta('two'), const StreamDone()],
        [const ContentDelta('three'), const StreamDone()],
      ]);
      var prompt = 'Be brief';
      final s = ChatSession(
        conversationId: _conv,
        persistenceThrottle: const Duration(milliseconds: 5),
        resolveDeps: () => depsWith(
          llm: llm,
          messages: messages,
          conversations: conversations,
          activeServers: [
            activeServer(
              tools: [tool('search')],
              instructions: 'Use search first.',
            ),
          ],
          systemPrompt: prompt,
        ),
      );
      await s.sendMessage('a');
      await s.sendMessage('b');
      prompt = 'Be thorough';
      await s.sendMessage('c');

      final ids = [
        for (final m in persisted())
          if (m.role == MessageRole.assistant) statsOf(m).requestContextId,
      ];
      expect(ids[0], ids[1]);
      expect(ids[2], isNot(ids[1]));
      final contexts = conversations.requestContexts[_conv]!;
      expect(contexts, hasLength(2));
      expect(
        contexts[ids[0]]!.systemPrompt,
        'Be brief\n\n## MCP Server: srv\nUse search first.',
      );
      expect(contexts[ids[2]]!.systemPrompt, startsWith('Be thorough'));
    });

    test('an image model is sent no context and records none', () async {
      await session(
        FakeLlmService.events([
          [const ContentDelta('ok'), const StreamDone()],
        ]),
        profile: const ImageRequestProfile(),
      ).sendMessage('draw');
      expect(statsOf(persisted().last).requestContextId, isNull);
      expect(conversations.requestContexts[_conv], isNull);
    });

    test('the placeholder carries the turn so far, unfinished', () async {
      final gate = Completer<void>();
      final llm = FakeLlmService([
        (_) async* {
          yield const ContentDelta('par');
          await gate.future;
          yield const StreamDone();
        },
      ]);
      final send = session(llm).sendMessage('hi');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final placeholder = persisted().last;
      expect(placeholder.isStreaming, isTrue);
      expect(statsOf(placeholder).outcome, GenerationOutcome.interrupted);
      expect(statsOf(placeholder).model, 'fake-model');

      gate.complete();
      await send;
      expect(statsOf(persisted().last).outcome, GenerationOutcome.completed);
    });

    test('a stopped reply says so, its duration kept', () async {
      final stalled = Completer<void>();
      final llm = FakeLlmService([
        (token) async* {
          yield const ContentDelta('Let me');
          await stalled.future;
          yield const StreamCancelled();
        },
      ]);
      final s = session(llm);
      final send = s.sendMessage('hi');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stop = s.stop();
      stalled.complete();
      await stop;
      await send;

      final reply = persisted().last;
      expect(statsOf(reply).outcome, GenerationOutcome.cancelled);
      expect(reply.durationMs, statsOf(reply).durationMs);
      expect(reply.durationMs, greaterThan(0));
    });

    test('a failed reply keeps the error', () async {
      await session(
        FakeLlmService.events([
          [const ContentDelta('partial'), const StreamError('boom')],
        ]),
      ).sendMessage('hi');
      final stats = statsOf(persisted().last);
      expect(stats.outcome, GenerationOutcome.failed);
      expect(stats.error, 'boom');
    });

    test('a tool result records its call time and server', () async {
      await session(
        FakeLlmService.events([
          [..._toolCall, const StreamDone()],
          [const ContentDelta('Answer'), const StreamDone()],
        ]),
      ).sendMessage('search dart');

      final result = persisted().singleWhere((m) => m.role == MessageRole.tool);
      final stats = result.stats! as ToolCallStats;
      expect(stats.serverId, 'srv');
      expect(stats.serverName, 'srv');
      expect(result.durationMs, stats.durationMs);
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
          DescribedImage(bytes: pngBytes, mimeType: 'image/png'),
          DescribedImage(bytes: pngBytes, mimeType: 'image/jpeg'),
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
          images: [DescribedImage(bytes: pngBytes, mimeType: 'image/png')],
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

    const shown = PhotoSummary(
      camera: CameraInfo(make: 'Apple', model: 'iPhone 17'),
      location: GeoLocation(latitude: 42.56858, longitude: 8.75145),
    );
    const blocks = kPhotoBlocks;
    const photo = PhotoMetadata(summary: shown, blocks: blocks);
    DescribedImage photoImage() =>
        DescribedImage(bytes: pngBytes, mimeType: 'image/png', metadata: photo);
    final edit = [
      ImageDelta(bytes: pngBytes, mimeType: 'image/png'),
      const StreamDone(),
    ];

    ImageContentBlock lastImage() =>
        persisted().last.content.whereType<ImageContentBlock>().single;

    /// [image]'s photo metadata: what is shown, the stored blocks, and the
    /// message that owns them.
    (PhotoSummary, PhotoMetadataBlocks?, String?) stored(
      ImageContentBlock image,
    ) {
      final ref = image.photoMetadata!;
      final id = ref.blocksId;
      return (
        ref.summary,
        id == null ? null : attachments.photoMetadata[id],
        id == null ? null : attachments.owners[id],
      );
    }

    test('an attached photo: shown on its block, blocks alongside', () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('nice'), const StreamDone()],
      ]);
      await imageSession(llm).sendMessage(
        'look',
        images: [
          photoImage(),
          DescribedImage(bytes: pngBytes, mimeType: 'image/png'),
        ],
      );

      final user = persisted().first;
      final [withPhoto, plain] = user.content
          .whereType<ImageContentBlock>()
          .toList();
      expect(stored(withPhoto), (shown, blocks, user.id));
      expect(plain.photoMetadata, isNull);
      // The blocks are not an image: not loaded as one, not sent.
      final metadataId = withPhoto.photoMetadata!.blocksId!;
      expect(user.imageAttachmentIds(), isNot(contains(metadataId)));
      expect(await attachments.loadBytes(metadataId), isNull);
      expect(llm.receivedHistories.single.single.imageAttachmentIds(), [
        withPhoto.attachmentId,
        plain.attachmentId,
      ]);
    });

    test('an edit of the photo inherits a copy of its own', () async {
      final llm = FakeLlmService.events([edit]);
      await imageSession(
        llm,
      ).sendMessage('make the sky orange', images: [photoImage()]);

      final [user, reply] = persisted();
      final source = user.content.whereType<ImageContentBlock>().single;
      expect(stored(lastImage()), (shown, blocks, reply.id));
      expect(
        lastImage().photoMetadata!.blocksId,
        isNot(source.photoMetadata!.blocksId),
      );
      expect(lastImage().aiOrigin, AiOrigin.editedPhoto);
    });

    test(
      'the inherited blocks are stored before the reply refers to them',
      () async {
        final checked = messages = _ReferencesChecked();
        final llm = FakeLlmService.events([
          [...edit.take(1), ...edit],
        ]);
        await imageSession(
          llm,
        ).sendMessage('two takes', images: [photoImage()]);
        checked.attachments = attachments;

        final images = persisted().last.content.whereType<ImageContentBlock>();
        expect(images, hasLength(2));
        // One copy for the turn, shared by its images.
        expect(
          images.map((i) => i.photoMetadata!.blocksId).toSet(),
          hasLength(1),
        );
        expect(checked.unresolved, isEmpty);
      },
    );

    test(
      'an edited screenshot is an edited photo, inheriting nothing',
      () async {
        final llm = FakeLlmService.events([edit]);
        await imageSession(llm).sendMessage(
          'crop it',
          images: [DescribedImage(bytes: pngBytes, mimeType: 'image/png')],
        );

        expect(lastImage().photoMetadata, isNull);
        expect(lastImage().aiOrigin, AiOrigin.editedPhoto);
      },
    );

    test('with nothing to start from, the image is generated', () async {
      final llm = FakeLlmService.events([edit]);
      await imageSession(llm).sendMessage('a cat');

      expect(lastImage().photoMetadata, isNull);
      expect(lastImage().aiOrigin, AiOrigin.generated);
    });

    test('a result sent again keeps how it was made', () async {
      final llm = FakeLlmService.events([
        [const ContentDelta('ok'), const StreamDone()],
      ]);
      await imageSession(llm).sendMessage(
        'in the red area: a hat',
        images: [
          DescribedImage(
            bytes: pngBytes,
            mimeType: 'image/png',
            aiOrigin: AiOrigin.generated,
          ),
        ],
      );

      final block = persisted().first.content
          .whereType<ImageContentBlock>()
          .single;
      expect(block.aiOrigin, AiOrigin.generated);
    });

    test('an image generated from the prompt alone inherits nothing', () async {
      final llm = FakeLlmService.events([
        [
          ImageDelta(bytes: pngBytes, mimeType: 'image/png', textToImage: true),
          const StreamDone(),
        ],
      ]);
      await imageSession(
        llm,
      ).sendMessage('a cat instead', images: [photoImage()]);

      expect(lastImage().photoMetadata, isNull);
      expect(lastImage().aiOrigin, AiOrigin.generated);
    });

    test('the metadata follows a chain of edits, a copy each', () async {
      final llm = FakeLlmService.events([edit, edit, edit]);
      final s = imageSession(llm);
      await s.sendMessage('make it blue', images: [photoImage()]);
      // No image attached: the server edits its latest output, and so the
      // new image inherits from it — twice.
      await s.sendMessage('add a hat');
      await s.sendMessage('now at night');

      final replies = persisted().where((m) => m.role == MessageRole.assistant);
      expect(replies, hasLength(3));
      for (final reply in replies) {
        final image = reply.content.whereType<ImageContentBlock>().single;
        expect(stored(image), (shown, blocks, reply.id));
      }
    });

    test('blocks an earlier build kept inline are inherited too', () async {
      await messages.saveMessage(
        testMessage(
          MessageRole.user,
          const [
            ImageContentBlock(
              attachmentId: 'old',
              mimeType: 'image/png',
              byteSize: 1,
              photoMetadata: PhotoMetadataRef(
                summary: shown,
                inlineBlocks: blocks,
              ),
            ),
          ],
          id: '0',
          conversationId: _conv,
        ),
      );
      final llm = FakeLlmService.events([edit]);
      await imageSession(llm).sendMessage('make it blue');

      expect(stored(lastImage()), (shown, blocks, persisted().last.id));
    });

    test('a fresh attachment without metadata breaks the chain', () async {
      final llm = FakeLlmService.events([edit, edit]);
      final s = imageSession(llm);
      await s.sendMessage('make it blue', images: [photoImage()]);
      await s.sendMessage(
        'use this one instead',
        images: [DescribedImage(bytes: pngBytes, mimeType: 'image/png')],
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

/// Records every attachment id a streaming upsert refers to that is not
/// stored yet (set [attachments] before the upserts to check).
class _ReferencesChecked extends InMemoryMessageRepository {
  InMemoryAttachmentRepository? attachments;
  final List<String> unresolved = [];

  @override
  Future<void> upsertStreamingMessage(Message message) {
    if (attachments case final stored?) {
      for (final image in message.content.whereType<ImageContentBlock>()) {
        for (final id in [image.attachmentId, ?image.photoMetadata?.blocksId]) {
          if (!stored.rows.containsKey(id)) unresolved.add(id);
        }
      }
    }
    return super.upsertStreamingMessage(message);
  }
}
