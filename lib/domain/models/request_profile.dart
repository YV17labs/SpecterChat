import 'app_settings.dart';
import 'image_settings.dart';

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
}

class TextRequestProfile extends RequestProfile {
  @override
  final GenerationSettings generation;

  const TextRequestProfile({this.generation = const GenerationSettings()});
}

class ImageRequestProfile extends RequestProfile {
  @override
  final ImageSettings image;

  const ImageRequestProfile({this.image = const ImageSettings()});
}
