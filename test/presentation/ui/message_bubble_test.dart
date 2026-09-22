import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/chat_session_state.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/message_stats.dart';
import 'package:specterchat/domain/services/llm_hook.dart';
import 'package:specterchat/presentation/ui/widgets/content_blocks.dart';
import 'package:specterchat/presentation/ui/widgets/message_bubble.dart';
import 'package:specterchat/presentation/ui/widgets/streaming_indicator.dart';

import '../../support/fakes.dart';
import '../../support/pump_app.dart';

void main() {
  testWidgets('user message renders its text and a fork button on hover', (
    tester,
  ) async {
    String? forked;
    await pumpApp(
      tester,
      MessageBubble(
        message: testMessage(MessageRole.user, [
          const ContentBlock.text(text: 'hi there'),
        ]),
        onFork: (t) => forked = t,
      ),
    );
    expect(find.text('hi there'), findsOneWidget);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('hi there')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fork to new conversation'));
    expect(forked, 'hi there');
  });

  testWidgets(
    'assistant message shows thinking, tool call with result, and stats',
    (tester) async {
      await pumpApp(
        tester,
        MessageBubble(
          message: testMessage(
            MessageRole.assistant,
            [
              const ContentBlock.thinking(text: 'let me think'),
              const ContentBlock.toolCall(
                id: 'tc-1',
                name: 'search',
                arguments: '{"q":"dart"}',
              ),
              const ContentBlock.text(text: 'Here you go'),
            ],
            completionTokens: 42,
            durationMs: 1000,
          ),
          toolResults: [
            testMessage(MessageRole.tool, [
              const ContentBlock.toolResult(
                toolCallId: 'tc-1',
                toolName: 'search',
                resultContent: [ContentBlock.text(text: 'found it')],
              ),
            ], id: 't'),
          ],
          cumulativeDurationMs: 3000,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ThinkingBlock), findsOneWidget);
      expect(find.byType(ToolCallBlock), findsOneWidget);
      expect(find.text('Tool: search'), findsOneWidget);
      expect(find.text('Here you go'), findsOneWidget);
      expect(find.textContaining('42 tokens'), findsOneWidget);
      expect(find.textContaining('Σ 3.0s'), findsOneWidget);
      // The result rendered inline, not as an orphan block.
      expect(find.byType(ToolResultBlock), findsNothing);

      await tester.tap(find.text('Tool: search'));
      await tester.pumpAndSettle();
      expect(find.text('found it'), findsOneWidget);
    },
  );

  testWidgets('unpaired tool result is still shown as an orphan block', (
    tester,
  ) async {
    await pumpApp(
      tester,
      MessageBubble(
        message: testMessage(MessageRole.assistant, [
          const ContentBlock.text(text: 'x'),
        ]),
        toolResults: [
          testMessage(MessageRole.tool, [
            const ContentBlock.toolResult(
              toolCallId: 'ghost',
              toolName: 'lost',
            ),
          ], id: 't'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ToolResultBlock), findsOneWidget);
    expect(find.text('Result: lost'), findsOneWidget);
  });

  testWidgets('streaming message shows the indicator and no stats', (
    tester,
  ) async {
    await pumpApp(
      tester,
      MessageBubble(
        message: testMessage(
          MessageRole.assistant,
          [const ContentBlock.text(text: 'partial')],
          isStreaming: true,
          completionTokens: 5,
          durationMs: 1000,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(StreamingIndicator), findsOneWidget);
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('auto-correction messages are labelled', (tester) async {
    await pumpApp(
      tester,
      MessageBubble(
        message: testMessage(MessageRole.user, [
          const ContentBlock.text(text: '$correctionPrefix and was discarded.'),
        ]),
      ),
    );
    expect(find.text('Auto-correction'), findsOneWidget);
  });

  testWidgets('a streaming message with progress shows the bar, not dots', (
    tester,
  ) async {
    await pumpApp(
      tester,
      MessageBubble(
        message: testMessage(MessageRole.assistant, [
          const ContentBlock.text(text: 'Generating…'),
        ], isStreaming: true),
        progress: const GenerationProgress(
          stage: 'generating',
          step: 12,
          total: 40,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(GenerationProgressBar), findsOneWidget);
    expect(find.byType(StreamingIndicator), findsNothing);
    expect(find.text('generating 12/40'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.3, 1e-9));
  });

  testWidgets('a streaming message without progress keeps the dots', (
    tester,
  ) async {
    await pumpApp(
      tester,
      MessageBubble(
        message: testMessage(MessageRole.assistant, [
          const ContentBlock.text(text: 'typing'),
        ], isStreaming: true),
      ),
    );
    await tester.pump();
    expect(find.byType(StreamingIndicator), findsOneWidget);
    expect(find.byType(GenerationProgressBar), findsNothing);
  });

  group('stats line', () {
    final stats = testGenerationStats();

    Message reply(GenerationStats stats) => testMessage(MessageRole.assistant, [
      const ContentBlock.text(text: 'ok'),
    ], stats: stats);

    testWidgets('speed is measured from the first token; details on hover', (
      tester,
    ) async {
      await pumpApp(tester, MessageBubble(message: reply(stats)));
      await tester.pumpAndSettle();

      // 354 tokens over 14.0s, not over the 15.7s the prompt included.
      expect(find.text('354 tokens  ·  15.7s  ·  25.3 tok/s'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip).last);
      expect(
        tooltip.message,
        'qwen3.8:27b-mlx · http://localhost:11434/v1\n'
        'Prompt: 25184 tokens · first token after 1.7s\n'
        'Reasoning: 7.3s\n'
        'Output: 354 tokens · in 14.0s · 25.3 tok/s\n'
        'Finish: tool_calls',
      );
    });

    testWidgets('a stopped reply without usage still shows its time', (
      tester,
    ) async {
      final stopped = stats.copyWith(
        completionTokens: null,
        outcome: GenerationOutcome.cancelled,
        durationMs: 3200,
      );
      await pumpApp(tester, MessageBubble(message: reply(stopped)));
      await tester.pumpAndSettle();
      expect(find.text('3.2s  ·  stopped'), findsOneWidget);
    });
  });
}
