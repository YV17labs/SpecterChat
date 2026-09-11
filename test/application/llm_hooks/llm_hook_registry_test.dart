import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/llm_hooks/llm_hook_registry.dart';
import 'package:specterchat/application/llm_hooks/qwen3.dart';
import 'package:specterchat/domain/services/llm_hook.dart';

class _BadHook implements LlmHook {
  @override
  RegExp get modelPattern => RegExp('bad');
  @override
  bool detectHallucination(String text) => false;
  @override
  String get hallucinationCorrection => 'no prefix here';
}

void main() {
  group('LlmHookRegistry', () {
    test('hookFor returns the first matching hook, else null', () {
      const registry = LlmHookRegistry([Qwen3Hook()]);
      expect(registry.hookFor('Qwen3-5-27B-Q5_K_M'), isA<Qwen3Hook>());
      expect(registry.hookFor('qwen3.6'), isA<Qwen3Hook>());
      expect(registry.hookFor('qwen3_5'), isA<Qwen3Hook>());
      expect(registry.hookFor('llama-3'), isNull);
      expect(registry.hookFor('qwen2.5'), isNull);
    });

    test('none() matches nothing', () {
      expect(const LlmHookRegistry.none().hookFor('qwen3.5'), isNull);
    });

    test('verify rejects corrections missing the shared prefix', () {
      expect(LlmHookRegistry([_BadHook()]).verify, throwsStateError);
      expect(defaultLlmHookRegistry.verify, returnsNormally);
    });
  });

  group('Qwen3Hook', () {
    const hook = Qwen3Hook();

    test('detects XML-style tool call markup, case-insensitively', () {
      expect(
        hook.detectHallucination('<tool_call>{"x":1}</tool_call>'),
        isTrue,
      );
      expect(hook.detectHallucination('<TOOL_CALL>'), isTrue);
      expect(hook.detectHallucination('<function=search>'), isTrue);
      expect(hook.detectHallucination('<invoke name="x">'), isTrue);
    });

    test('ignores ordinary prose and JSON', () {
      expect(hook.detectHallucination('Here is {"a": 1}'), isFalse);
      expect(hook.detectHallucination('call the function later'), isFalse);
    });

    test('correction starts with the shared prefix and echoes no markup', () {
      expect(hook.hallucinationCorrection, startsWith(correctionPrefix));
      expect(hook.hallucinationCorrection, isNot(contains('<tool_call>')));
    });
  });
}
