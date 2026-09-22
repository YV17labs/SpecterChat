import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/stream_accumulator.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';

void main() {
  group('ToolCallAccumulator', () {
    test('a call is valid once named; without an id it gets one', () {
      expect((ToolCallAccumulator()..id = 'x').isValid, isFalse);
      final named = ToolCallAccumulator()..name = 'x';
      expect(named.isValid, isTrue);
      expect(named.callId, startsWith('call_'));
      expect(named.callId, named.callId, reason: 'made up once');
      expect((named..id = 'srv-1').callId, 'srv-1');
    });

    test('accumulates argument fragments', () {
      final tc = ToolCallAccumulator();
      tc.argumentsBuffer.write('{"q":');
      tc.argumentsBuffer.write('"test"}');
      expect(tc.arguments, '{"q":"test"}');
    });
  });

  group('StreamAccumulator', () {
    late StreamAccumulator acc;

    setUp(() => acc = StreamAccumulator());

    test('content and thinking mark the buffer dirty', () {
      expect(acc.isDirty, isFalse);
      acc.addContent('a');
      expect(acc.isDirty, isTrue);
      expect(acc.content.toString(), 'a');
      acc.addThinking('t');
      expect(acc.thinking.toString(), 't');
    });

    test('first fragment of a tool call reports isNew, later ones do not', () {
      final first = acc.addToolCallDelta(
        const ToolCallDelta(
          index: 0,
          id: 'tc',
          name: 'search',
          argumentsDelta: '{',
        ),
      );
      final second = acc.addToolCallDelta(
        const ToolCallDelta(index: 0, argumentsDelta: '}'),
      );
      expect(first, isTrue);
      expect(second, isFalse);
      expect(acc.toolCalls.single.arguments, '{}');
      expect(acc.hasValidToolCalls, isTrue);
    });

    test('strips call-syntax noise from tool names', () {
      acc.addToolCallDelta(
        const ToolCallDelta(
          index: 0,
          id: 'tc',
          name: 'search(\n',
          argumentsDelta: '',
        ),
      );
      expect(acc.toolCalls.single.name, 'search');
    });

    test('isSendable with text or a valid tool call, not with thinking', () {
      expect(acc.isSendable, isFalse);
      acc.addThinking('hmm');
      expect(acc.isSendable, isFalse);
      acc.addContent('x');
      expect(acc.isSendable, isTrue);
    });

    test('isSendable with an image and reset clears images', () {
      final acc = StreamAccumulator();
      expect(acc.isSendable, isFalse);
      acc.addImage(
        const ImageContentBlock(
          attachmentId: 'att',
          mimeType: 'image/png',
          byteSize: 3,
        ),
      );
      expect(acc.isSendable, isTrue);
      expect(acc.isDirty, isTrue);
      acc.reset();
      expect(acc.images, isEmpty);
      expect(acc.isSendable, isFalse);
    });

    test('shouldPersist is true once after a change, then false', () {
      expect(acc.shouldPersist(), isFalse);
      acc.addContent('hello');
      expect(acc.shouldPersist(), isTrue);
      expect(acc.shouldPersist(), isFalse);
      expect(acc.shouldPersist(force: true), isTrue);
    });

    test('dropIncompleteToolCalls removes unparseable arguments', () {
      acc.addToolCallDelta(
        const ToolCallDelta(
          index: 0,
          id: 'a',
          name: 'ok',
          argumentsDelta: '{}',
        ),
      );
      acc.addToolCallDelta(
        const ToolCallDelta(
          index: 1,
          id: 'b',
          name: 'cut',
          argumentsDelta: '{"q":',
        ),
      );
      acc.dropIncompleteToolCalls();
      expect(acc.toolCalls.map((tc) => tc.name), ['ok']);
    });

    test('another id on the same index is another call', () {
      // Servers that number every call 0 must not have them merged.
      acc
        ..addToolCallDelta(
          const ToolCallDelta(
            index: 0,
            id: 'a',
            name: 'app_list',
            argumentsDelta: '{}',
          ),
        )
        ..addToolCallDelta(
          const ToolCallDelta(
            index: 0,
            id: 'b',
            name: 'app_running',
            argumentsDelta: '{',
          ),
        )
        ..addToolCallDelta(const ToolCallDelta(index: 0, argumentsDelta: '}'));
      expect(
        [for (final tc in acc.toolCalls) (tc.id, tc.name, tc.arguments)],
        [('a', 'app_list', '{}'), ('b', 'app_running', '{}')],
      );
    });

    test('reset clears everything', () {
      acc.addContent('x');
      acc.addToolCallDelta(
        const ToolCallDelta(index: 0, id: 'a', name: 'b', argumentsDelta: ''),
      );
      acc.reset();
      expect(acc.content.isEmpty, isTrue);
      expect(acc.toolCalls, isEmpty);
      expect(acc.isDirty, isFalse);
    });
  });
}
