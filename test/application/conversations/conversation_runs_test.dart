import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/conversations/conversation_runs.dart';
import 'package:specterchat/domain/models/message.dart';

import '../../support/fakes.dart';

void main() {
  // testMessage takes its token count and duration from the stats, as
  // the chat pipeline writes them.
  Message turn(String id, {int? prompt, int completion = 0, int ms = 0}) =>
      testMessage(
        MessageRole.assistant,
        const [],
        id: id,
        stats: testGenerationStats(
          promptTokens: prompt,
          completionTokens: completion,
          durationMs: ms,
        ),
      );

  group('cumulativeRunTotals', () {
    test('adds up the turns answering one user message', () {
      final totals = cumulativeRunTotals([
        testMessage(MessageRole.user, const [], id: 'u1'),
        turn('a1', prompt: 1000, completion: 100, ms: 2000),
        testMessage(MessageRole.tool, const [], id: 't1', durationMs: 5000),
        turn('a2', prompt: 1200, completion: 50, ms: 1000),
      ]);

      // The tool's time is not generation time; the context resent on the
      // second turn is counted again, because it was sent again.
      expect(totals['a1'], (
        promptTokens: 1000,
        completionTokens: 100,
        durationMs: 2000,
      ));
      expect(totals['a2'], (
        promptTokens: 2200,
        completionTokens: 150,
        durationMs: 3000,
      ));
      expect(totals.containsKey('u1'), isFalse);
      expect(totals.containsKey('t1'), isFalse);
    });

    test('starts over at the next user message', () {
      final totals = cumulativeRunTotals([
        testMessage(MessageRole.user, const [], id: 'u1'),
        turn('a1', prompt: 1000, completion: 100, ms: 2000),
        testMessage(MessageRole.user, const [], id: 'u2'),
        turn('a2', prompt: 1500, completion: 20, ms: 500),
      ]);

      expect(totals['a2'], (
        promptTokens: 1500,
        completionTokens: 20,
        durationMs: 500,
      ));
    });

    test('a turn whose server reported no usage still counts its time', () {
      final totals = cumulativeRunTotals([
        testMessage(MessageRole.user, const [], id: 'u1'),
        turn('a1', prompt: 1000, completion: 100, ms: 2000),
        turn('a2', ms: 800),
      ]);

      expect(totals['a2'], (
        promptTokens: 1000,
        completionTokens: 100,
        durationMs: 2800,
      ));
    });
  });
}
