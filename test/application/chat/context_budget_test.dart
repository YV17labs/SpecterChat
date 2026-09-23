import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/chat/context_budget.dart';
import 'package:specterchat/domain/models/message.dart';

import '../../support/fakes.dart';

Message _user(String text, {String id = 'm'}) =>
    testMessage(MessageRole.user, [ContentBlock.text(text: text)], id: id);

Message _assistant(List<ContentBlock> content, {String id = 'm'}) =>
    testMessage(MessageRole.assistant, content, id: id);

Message _toolResult(String text, {required String id, bool image = false}) =>
    testMessage(MessageRole.tool, [
      ContentBlock.toolResult(
        toolCallId: 'tc-$id',
        toolName: 'screenshot',
        resultContent: [
          ContentBlock.text(text: text),
          if (image) _image,
        ],
      ),
    ], id: id);

const _image = ContentBlock.image(
  attachmentId: 'att',
  mimeType: 'image/png',
  byteSize: 3,
);

/// A user message heavy enough to matter beside [kImageTokens]: 1000
/// tokens of text, plus the framing.
Message _heavy(String id) => _user('x' * 4000, id: id);

/// The text a tool result still carries.
String _resultText(Message message) => message.content
    .whereType<ToolResultContentBlock>()
    .single
    .resultContent
    .whereType<TextContentBlock>()
    .map((b) => b.text)
    .join();

void main() {
  group('estimateMessageTokens', () {
    test('text is its UTF-8 bytes over four, plus the message framing', () {
      expect(estimateMessageTokens(_user('x' * 400)), kMessageTokens + 100);
    });

    test('a multi-byte character counts as the bytes it takes', () {
      // "é" takes two bytes, so two of them are one token, not half of one.
      expect(estimateMessageTokens(_user('éé')), kMessageTokens + 1);
    });

    test('an image is a flat cost, whatever it weighs on disk', () {
      expect(
        estimateMessageTokens(_assistant([_image])),
        kMessageTokens + kImageTokens,
      );
    });

    test('reasoning is not counted: it never reaches the wire', () {
      final withThinking = _assistant([
        ContentBlock.thinking(text: 'x' * 4000),
        const ContentBlock.text(text: 'ok'),
      ]);
      expect(
        estimateMessageTokens(withThinking),
        estimateMessageTokens(_user('ok')),
      );
    });

    test('a tool call counts its name and its arguments', () {
      final call = _assistant([
        const ContentBlock.toolCall(
          id: 'tc-1',
          name: 'search',
          arguments: '{"q":"tokens"}',
        ),
      ]);
      // 6 bytes of name + 14 of arguments = 20 bytes = 5 tokens.
      expect(estimateMessageTokens(call), kMessageTokens + 5);
    });

    test('a tool result counts the text and the images it returned', () {
      expect(
        estimateMessageTokens(_toolResult('xxxx', id: 'a', image: true)),
        kMessageTokens + 1 + kImageTokens,
      );
    });
  });

  group('ContextBudget', () {
    test('the prompt gets the window less the answer and the buffer', () {
      const budget = ContextBudget(contextLength: 10000, answerTokens: 2000);
      expect(budget.maxPromptTokens, 10000 - 2000 - 1000);
    });

    test('no window set means nothing is weighed', () {
      const budget = ContextBudget(contextLength: 0, answerTokens: 2000);
      expect(budget.maxPromptTokens, isNull);
      expect(budget.isUnlimited, isTrue);
    });

    test('an answer larger than the window leaves the prompt nothing', () {
      const budget = ContextBudget(contextLength: 1000, answerTokens: 4096);
      expect(budget.maxPromptTokens, 0);
    });

    test('an image limit alone still gives the budget work to do', () {
      const budget = ContextBudget(
        contextLength: 0,
        answerTokens: 0,
        imageLimit: 1,
      );
      expect(budget.isUnlimited, isFalse);
    });
  });

  group('trimHistory', () {
    test('an unlimited budget hands back the very same list', () {
      final history = [
        _user('hello'),
        _assistant([_image]),
      ];
      final trimmed = trimHistory(history, const ContextBudget.unlimited());
      expect(trimmed.history, same(history));
      expect(trimmed.droppedRuns, 0);
      expect(trimmed.droppedImages, 0);
    });

    test('a history that fits is not touched', () {
      final history = [
        _user('hello'),
        _assistant([const ContentBlock.text(text: 'hi')]),
      ];
      final trimmed = trimHistory(
        history,
        const ContextBudget(contextLength: 10000, answerTokens: 1000),
      );
      expect(trimmed.history, same(history));
      expect(trimmed.droppedRuns, 0);
    });

    test('only the newest images stay, older ones leave their message', () {
      final history = [
        _user('one', id: 'a'),
        _assistant([const ContentBlock.text(text: 'first'), _image], id: 'b'),
        _user('two', id: 'c'),
        _assistant([const ContentBlock.text(text: 'second'), _image], id: 'd'),
      ];
      final trimmed = trimHistory(
        history,
        const ContextBudget(contextLength: 0, answerTokens: 0, imageLimit: 1),
      );
      expect(trimmed.droppedImages, 1);
      expect(trimmed.history[1].hasImages, isFalse);
      expect(trimmed.history[3].hasImages, isTrue);
      // The text of the message that lost its picture is still there.
      expect(trimmed.history[1].plainText, 'first');
    });

    test('an image inside a tool result falls under the same limit', () {
      final history = [
        _toolResult('old', id: 'a', image: true),
        _toolResult('new', id: 'b', image: true),
      ];
      final trimmed = trimHistory(
        history,
        const ContextBudget(contextLength: 0, answerTokens: 0, imageLimit: 1),
      );
      expect(trimmed.droppedImages, 1);
      expect(trimmed.history[0].hasImages, isFalse);
      expect(trimmed.history[1].hasImages, isTrue);
      // What the tool said survives the loss of what it showed.
      expect(_resultText(trimmed.history[0]), 'old');
    });

    test('what still does not fit is dropped one whole run at a time', () {
      final history = [_heavy('a'), _heavy('b'), _heavy('c')];
      final trimmed = trimHistory(
        history,
        const ContextBudget(contextLength: 3000, answerTokens: 500),
      );
      expect(trimmed.droppedRuns, 1);
      expect(trimmed.history.map((m) => m.id), ['b', 'c']);
    });

    test('the last run stays even when it alone is over budget', () {
      final history = [_heavy('a'), _heavy('b')];
      final trimmed = trimHistory(
        history,
        const ContextBudget(contextLength: 200, answerTokens: 0),
      );
      expect(trimmed.history.map((m) => m.id), ['b']);
      expect(trimmed.droppedRuns, 1);
    });

    test('a tool call is never separated from the result answering it', () {
      final history = [
        _heavy('a'),
        _assistant([
          const ContentBlock.toolCall(
            id: 'tc-1',
            name: 'search',
            arguments: '{}',
          ),
        ], id: 'b'),
        _toolResult('found', id: 'c'),
        _heavy('d'),
      ];
      final trimmed = trimHistory(
        history,
        const ContextBudget(contextLength: 1200, answerTokens: 0),
      );
      // The run that called the tool left whole, with its result.
      expect(trimmed.history.map((m) => m.id), ['d']);
      expect(trimmed.droppedRuns, 1);
    });

    test('images go first: what fits without them keeps all its turns', () {
      final history = [
        _user('one', id: 'a'),
        _assistant([_image], id: 'b'),
        _user('two', id: 'c'),
        _assistant([_image], id: 'd'),
      ];
      // Room for one picture and the text, not for two pictures.
      const window = ContextBudget(contextLength: 1300, answerTokens: 0);

      final withoutLimit = trimHistory(history, window);
      expect(withoutLimit.droppedRuns, 1);
      expect(withoutLimit.droppedImages, 0);

      final withLimit = trimHistory(
        history,
        const ContextBudget(
          contextLength: 1300,
          answerTokens: 0,
          imageLimit: 1,
        ),
      );
      expect(withLimit.droppedImages, 1);
      expect(withLimit.droppedRuns, 0);
      expect(withLimit.history.map((m) => m.id), ['a', 'b', 'c', 'd']);
    });
  });
}
