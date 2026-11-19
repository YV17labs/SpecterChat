import 'package:freezed_annotation/freezed_annotation.dart';

part 'model_info.freezed.dart';
part 'model_info.g.dart';

/// One entry of the server's model list.
///
/// A plain text LLM has [image] `null`. A model the server says makes
/// images has an [image] description (Pictor, see
/// `../pictor/PROTOCOL.md`, describes itself in full; other servers only
/// say so); the UI switches to image settings when it is present.
@freezed
abstract class ModelInfo with _$ModelInfo {
  const factory ModelInfo({required String id, ImageModelInfo? image}) =
      _ModelInfo;

  const ModelInfo._();

  factory ModelInfo.fromJson(Map<String, dynamic> json) =>
      _$ModelInfoFromJson(json);

  bool get isImage => image != null;
}

/// What an image-generation backend can do today. Every flag defaults to
/// the most permissive reading of "unknown" except the ones that would make
/// the UI offer something the server cannot deliver.
@freezed
abstract class ImageCapabilities with _$ImageCapabilities {
  const factory ImageCapabilities({
    @Default(true) bool textToImage,
    @Default(false) bool referenceEdit,
    @Default(0) int maxReferenceImages,
    @Default(false) bool rgba,
    @Default(2048) int maxSide,

    /// Set when the model runs a sampling schedule baked into its
    /// checkpoint (a distilled "turbo" model): this many steps, whatever
    /// a request asks for.
    int? fixedSteps,
  }) = _ImageCapabilities;

  factory ImageCapabilities.fromJson(Map<String, dynamic> json) =>
      _$ImageCapabilitiesFromJson(json);
}

/// Server-side defaults and allowed choices. Used as the starting values
/// of the image settings UI. The choices have built-in fallbacks for a
/// server that does not list them; a default it does not give is `null`
/// — they differ from one model to the next (8 steps for a distilled one,
/// 40 for its base), so the UI shows "server default" rather than a guess
/// it would then fail to send.
@freezed
abstract class ImageDefaults with _$ImageDefaults {
  const factory ImageDefaults({
    int? steps,
    @Default(100) int maxSteps,
    @Default(1024) int baseSize,
    @Default([768, 1024, 1536, 2048]) List<int> baseSizes,
    @Default(['1:1', '4:3', '3:4', '3:2', '2:3', '16:9', '9:16', '21:9'])
    List<String> aspectRatios,
    double? guidance,
  }) = _ImageDefaults;

  factory ImageDefaults.fromJson(Map<String, dynamic> json) =>
      _$ImageDefaultsFromJson(json);
}

/// How an image model is asked for a picture. Decided with the model,
/// from the field the server used to say it makes images: no OpenAI-style
/// server says how to ask, and the field it uses is what tells them apart.
enum ImageApi {
  /// `chat/completions` with the `generation` extension object (Pictor,
  /// `../pictor/PROTOCOL.md`).
  chatGeneration,

  /// The OpenAI Images API, `POST /images/generations` (mlx-serve, which
  /// takes the image to edit there too).
  imagesEndpoint,
}

/// The settings the model's authors recommend — the quality they publish,
/// not the speed a user may prefer. Shown next to the controls; each is
/// `null` when nothing is recommended.
@freezed
abstract class ImageRecommendations with _$ImageRecommendations {
  const factory ImageRecommendations({
    int? steps,
    double? guidance,
    int? baseSize,
  }) = _ImageRecommendations;

  factory ImageRecommendations.fromJson(Map<String, dynamic> json) =>
      _$ImageRecommendationsFromJson(json);
}

@freezed
abstract class ImageModelInfo with _$ImageModelInfo {
  const factory ImageModelInfo({
    // Every image model cached before this field existed came from Pictor.
    @JsonKey(unknownEnumValue: ImageApi.chatGeneration)
    @Default(ImageApi.chatGeneration)
    ImageApi api,
    @Default('') String backend,
    @Default('') String device,
    @Default(ImageCapabilities()) ImageCapabilities capabilities,
    @Default(ImageDefaults()) ImageDefaults defaults,
    @Default(ImageRecommendations()) ImageRecommendations recommended,
  }) = _ImageModelInfo;

  const ImageModelInfo._();

  factory ImageModelInfo.fromJson(Map<String, dynamic> json) =>
      _$ImageModelInfoFromJson(json);

  /// Whether the model can answer in words (`ImageMode.chat`): the Images
  /// API returns pictures and nothing else.
  bool get canChat => api != ImageApi.imagesEndpoint;
}
