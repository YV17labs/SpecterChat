import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/infrastructure/llm/sse_think_splitter.dart';

(String thinking, String content) _run(List<String> deltas) {
  final splitter = SseThinkSplitter();
  final events = <StreamEvent>[];
  for (final d in deltas) {
    events.addAll(splitter.push(d));
  }
  events.addAll(splitter.flush());
  return (
    events.whereType<ThinkingDelta>().map((e) => e.text).join(),
    events.whereType<ContentDelta>().map((e) => e.text).join(),
  );
}

void main() {
  test('plain content passes through', () {
    expect(_run(['Hello', ' world']), ('', 'Hello world'));
  });

  test('splits a complete think block inside one delta', () {
    expect(_run(['<think>plan</think>do it']), ('plan', 'do it'));
  });

  test('splits tags spanning several deltas', () {
    expect(_run(['prefix <th', 'ink>secret</th', 'ink>visible']), (
      'secret',
      'prefix visible',
    ));
  });

  test('strips the blank line some models emit after </think>', () {
    expect(_run(['<think>r</think>\n\nThe answer']), ('r', 'The answer'));
  });

  test('an unterminated think block flushes as thinking', () {
    expect(_run(['<think>still going']), ('still going', ''));
  });

  test('a lone < that is not a tag is not held back forever', () {
    expect(_run(['a < b', ' and c']), ('', 'a < b and c'));
  });
}
