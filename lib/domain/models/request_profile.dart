import 'app_settings.dart';
import 'image_settings.dart';
import 'message.dart';
import 'model_info.dart';

/// What a chat-completion request carries besides the messages.
///
/// A text LLM gets the sampling parameters, the system prompt and the
/// tools; an image-generation server gets the image options and none of
/// those (it ignores them anyway). Resolved per send from the selected
/// model, and snapshotted in `ChatSessionDeps` so a setting changed
/// mid-stream only affects the next turn.
sealed class RequestProfile {
  const RequestProfile();

  /// Sampling parameters, `null` for an image model.
  GenerationSettings? get generation => null;

  /// Image options, `null` for a text model.
  ImageSettings? get image => null;

  /// How an image model is asked, `null` for a text model.
  ImageApi? get imageApi => null;

  /// The images of [history] a request with this profile sends, by
  /// attachment id: what has to be loaded for it, and nothing else. A
  /// chat request carries the conversation, so every image in it.
  Set<String> imageIdsSent(List<Message> history) => {
    for (final message in history) ...message.imageAttachmentIds(),
  };

  /// This profile as one turn sends it, which is also what the turn
  /// records it was produced with. Only the seed of an Images API request
  /// differs: an empty seed means a new picture every time
  /// ([ImageSettings.seed]); Pictor draws one itself, the Images API
  /// falls back on a fixed one (42 on mlx-serve) — so [drawSeed] gives
  /// that turn its own.
  RequestProfile forTurn(int Function() drawSeed) => switch (this) {
    ImageRequestProfile(api: ImageApi.imagesEndpoint, :final image)
        when image.seed == null =>
      ImageRequestProfile(
        image: image.copyWith(seed: drawSeed()),
        api: ImageApi.imagesEndpoint,
      ),
    _ => this,
  };
}

class TextRequestProfile extends RequestProfile {
  @override
  final GenerationSettings generation;

  const TextRequestProfile({this.generation = const GenerationSettings()});
}

class ImageRequestProfile extends RequestProfile {
  @override
  final ImageSettings image;

  /// How the selected model is asked, as `GET /models` said
  /// ([ImageModelInfo.api]).
  final ImageApi api;

  const ImageRequestProfile({
    this.image = const ImageSettings(),
    this.api = ImageApi.chatGeneration,
  });

  @override
  ImageApi get imageApi => api;

  /// The images an Images API turn is sent. That API reads no
  /// conversation and decides nothing: a request with an image is an
  /// edit, one without is a new picture. So the mode says which, the way
  /// both the API and Pictor read it:
  /// - Generate: none;
  /// - Auto: the images attached to the last message ([attachedImagesOf])
  ///   — none attached is a new picture, whatever the conversation holds;
  /// - Edit: those, else the conversation's latest picture
  ///   ([referenceImagesOf]) — "now make it blue".
  List<ImageContentBlock> sourceImagesOf(List<Message> history) =>
      switch (image.mode) {
        ImageMode.generate => const [],
        ImageMode.edit => referenceImagesOf(history),
        ImageMode.auto || ImageMode.chat || null => attachedImagesOf(history),
      };

  /// A Pictor request carries the conversation; an Images API one only
  /// what it works from ([sourceImagesOf]).
  @override
  Set<String> imageIdsSent(List<Message> history) => switch (api) {
    ImageApi.chatGeneration => super.imageIdsSent(history),
    ImageApi.imagesEndpoint => {
      for (final image in sourceImagesOf(history)) image.attachmentId,
    },
  };
}
