import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/generation_recorder.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/message_stats.dart';
import 'package:specterchat/domain/models/request_profile.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';

void main() {
  var clock = 0;
  final start = DateTime.utc(2026, 9, 22, 10);

  GenerationRecorder recorder({
    RequestProfile profile = const TextRequestProfile(
      generation: GenerationSettings(temperature: 0.6),
    ),
  }) => GenerationRecorder(
    model: 'qwen3',
    endpoint: 'http://localhost:11434/v1',
    profile: profile,
    requestContextId: 'ctx-1',
    retry: 1,
    now: () => start,
    elapsedMs: () => clock,
  );

  setUp(() => clock = 0);

  test('measures first token, first answer, fragments and usage', () {
    final r = recorder();
    clock = 1800;
    r.record(const ThinkingDelta('hmm'));
    clock = 2000;
    r.record(const ThinkingDelta('…'));
    clock = 9000;
    r.record(const ContentDelta('Hi'));
    r.record(
      const ToolCallDelta(
        index: 0,
        id: 't',
        name: 'search',
        argumentsDelta: '',
      ),
    );
    r.record(const StreamUsage(promptTokens: 25184, completionTokens: 354));
    r.record(const ServerReport({'model': 'qwen3'}));
    r.record(const ServerReport({'finish_reason': 'tool_calls'}));
    clock = 15700;

    final stats = r.finish(GenerationOutcome.completed);

    expect(
      stats,
      GenerationStats(
        model: 'qwen3',
        endpoint: 'http://localhost:11434/v1',
        generation: const GenerationSettings(temperature: 0.6),
        requestContextId: 'ctx-1',
        retry: 1,
        startedAt: start,
        durationMs: 15700,
        firstTokenMs: 1800,
        firstAnswerMs: 9000,
        fragments: 4,
        promptTokens: 25184,
        completionTokens: 354,
        outcome: GenerationOutcome.completed,
        server: const {'model': 'qwen3', 'finish_reason': 'tool_calls'},
      ),
    );
    expect(stats.generationMs, 13900);
    expect(stats.reasoningMs, 7200);
    expect(stats.outputTokensPerSecond, closeTo(25.47, 0.01));
    expect(stats.finishReason, 'tool_calls');
  });

  test('an image model records its options, not sampling', () {
    const image = ImageSettings(steps: 7);
    final r = recorder(profile: const ImageRequestProfile(image: image));
    clock = 30000;
    r.record(ImageDelta(bytes: Uint8List(1), mimeType: 'image/png'));
    final stats = r.finish(GenerationOutcome.completed);
    expect(stats.image, image);
    expect(stats.generation, isNull);
    expect(stats.firstAnswerMs, 30000);
    expect(stats.reasoningMs, isNull);
  });

  test('a snapshot is an unfinished turn; finish freezes the clock', () {
    final r = recorder();
    clock = 500;
    expect(r.snapshot().outcome, GenerationOutcome.interrupted);
    expect(r.snapshot().durationMs, 500);

    clock = 800;
    final stats = r.finish(GenerationOutcome.failed, error: 'API error: 500');
    clock = 5000;
    r.record(const ContentDelta('late'));

    expect(stats.error, 'API error: 500');
    expect(r.snapshot(), stats);
    expect(r.finish(GenerationOutcome.completed), stats);
    expect(stats.durationMs, 800);
    expect(stats.firstTokenMs, isNull);
    expect(stats.completionTokens, isNull);
  });
}
