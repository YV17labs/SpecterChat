import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/stream_accumulator.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';

void main() {
  group('ToolCallAccumulator', () {
    test('isValid only when both id and name are set', () {
      expect((ToolCallAccumulator()..name = 'x').isValid, isFalse);
      expect((ToolCallAccumulator()..id = 'x').isValid, isFalse);
      expect(
        (ToolCallAccumulator()
              ..id = 'x'
              ..name = 'y')
            .isValid,
        isTrue,
      );
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
      expect(acc.toolCalls[0]!.arguments, '{}');
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
      expect(acc.toolCalls[0]!.name, 'search');
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
      expect(acc.toolCalls.keys, [0]);
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
