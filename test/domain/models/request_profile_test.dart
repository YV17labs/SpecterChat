import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/domain/models/request_profile.dart';

ContentBlock _text(String text) => ContentBlock.text(text: text);

ContentBlock _image(String id) =>
    ContentBlock.image(attachmentId: id, mimeType: 'image/png', byteSize: 1);

Message _message(MessageRole role, List<ContentBlock> content) => Message(
  id: 'm',
  conversationId: 'c',
  role: role,
  content: content,
  createdAt: DateTime(2024),
);

Message _user(List<ContentBlock> content) =>
    _message(MessageRole.user, content);

Message _assistant(List<ContentBlock> content) =>
    _message(MessageRole.assistant, content);

ImageRequestProfile _imagesApi([ImageMode? mode]) => ImageRequestProfile(
  image: ImageSettings(mode: mode),
  api: ImageApi.imagesEndpoint,
);

void main() {
  // A fox was drawn, then a cat; the user now writes without attaching.
  final afterTwoPictures = [
    _user([_text('a fox')]),
    _assistant([_image('fox')]),
    _user([_text('a cat')]),
    _assistant([_image('cat')]),
    _user([_text('a city skyline at night')]),
  ];
  // The same conversation, the last message handing two images over.
  final withAttachments = [
    ...afterTwoPictures.take(4),
    _user([_text('put the hat from 2 on 1'), _image('a'), _image('b')]),
  ];

  List<String> sources(ImageMode? mode, List<Message> history) => [
    for (final image in _imagesApi(mode).sourceImagesOf(history))
      image.attachmentId,
  ];

  group('ImageRequestProfile.sourceImagesOf', () {
    test('Auto edits what is attached, and only that', () {
      expect(sources(null, withAttachments), ['a', 'b']);
      expect(sources(ImageMode.auto, withAttachments), ['a', 'b']);
      // Nothing attached is a new picture, whatever was drawn before.
      expect(sources(null, afterTwoPictures), isEmpty);
      expect(sources(ImageMode.auto, afterTwoPictures), isEmpty);
    });

    test('Edit falls back on the latest picture: "now make it blue"', () {
      expect(sources(ImageMode.edit, withAttachments), ['a', 'b']);
      expect(sources(ImageMode.edit, afterTwoPictures), ['cat']);
      expect(
        sources(ImageMode.edit, [
          _user([_text('make it blue')]),
        ]),
        isEmpty,
      );
    });

    test('Generate sends none, attached or not', () {
      expect(sources(ImageMode.generate, withAttachments), isEmpty);
      expect(sources(ImageMode.generate, afterTwoPictures), isEmpty);
    });

    test('Chat, kept from a model that had it, reads as Auto', () {
      expect(sources(ImageMode.chat, withAttachments), ['a', 'b']);
      expect(sources(ImageMode.chat, afterTwoPictures), isEmpty);
    });

    test('no user message, no image', () {
      for (final mode in [null, ...ImageMode.values]) {
        expect(sources(mode, const []), isEmpty);
        expect(
          sources(mode, [
            _assistant([_image('x')]),
          ]),
          isEmpty,
        );
      }
    });
  });

  group('RequestProfile.imageIdsSent', () {
    final history = [
      _user([_text('look'), _image('a')]),
      _message(MessageRole.tool, [
        ContentBlock.toolResult(
          toolCallId: 't',
          toolName: 'shot',
          resultContent: [_image('a'), _image('b')],
        ),
      ]),
      _assistant([_image('c')]),
      _user([_text('again')]),
    ];

    test('a chat carries every image of the history, each once', () {
      expect(const TextRequestProfile().imageIdsSent(history), {'a', 'b', 'c'});
      // Pictor reads the whole conversation too.
      expect(const ImageRequestProfile().imageIdsSent(history), {
        'a',
        'b',
        'c',
      });
    });

    test('an Images API turn carries only what it works from', () {
      expect(_imagesApi().imageIdsSent(history), isEmpty);
      expect(_imagesApi(ImageMode.edit).imageIdsSent(history), {'c'});
      expect(_imagesApi(ImageMode.generate).imageIdsSent(history), isEmpty);
      expect(_imagesApi().imageIdsSent(withAttachments), {'a', 'b'});
    });
  });

  group('RequestProfile.forTurn', () {
    int draw() => 1234;
    int never() => fail('no seed to draw');

    test('an Images API turn without a seed draws its own', () {
      final turn = _imagesApi(ImageMode.edit).forTurn(draw);
      expect(turn.image, const ImageSettings(mode: ImageMode.edit, seed: 1234));
      expect(turn.imageApi, ImageApi.imagesEndpoint);
    });

    test('a seed the user set is kept', () {
      const profile = ImageRequestProfile(
        image: ImageSettings(seed: 7),
        api: ImageApi.imagesEndpoint,
      );
      expect(profile.forTurn(never), same(profile));
    });

    test('Pictor draws its own, a text model has none', () {
      const pictor = ImageRequestProfile();
      const text = TextRequestProfile();
      expect(pictor.forTurn(never), same(pictor));
      expect(text.forTurn(never), same(text));
      expect(pictor.imageApi, ImageApi.chatGeneration);
      expect(text.imageApi, isNull);
    });
  });
}
