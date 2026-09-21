import 'package:freezed_annotation/freezed_annotation.dart';

part 'model_info.freezed.dart';
part 'model_info.g.dart';

/// One entry of the server's model list.
///
/// A plain text LLM has [image] `null`. An image-generation server
/// (Pictor, see `../pictor/PROTOCOL.md`) describes itself in
/// [image]; the UI switches to image settings when it is present.
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
  }) = _ImageCapabilities;

  factory ImageCapabilities.fromJson(Map<String, dynamic> json) =>
      _$ImageCapabilitiesFromJson(json);
}

/// Server-side defaults and allowed choices. Used as the starting values
/// of the image settings UI; a server that predates `defaults` gets these
/// built-in fallbacks.
@freezed
abstract class ImageDefaults with _$ImageDefaults {
  const factory ImageDefaults({
    @Default(20) int steps,
    @Default(100) int maxSteps,
    @Default(1024) int baseSize,
    @Default([768, 1024, 1536, 2048]) List<int> baseSizes,
    @Default(['1:1', '4:3', '3:4', '3:2', '2:3', '16:9', '9:16', '21:9'])
    List<String> aspectRatios,
    @Default(1.0) double guidance,
  }) = _ImageDefaults;

  factory ImageDefaults.fromJson(Map<String, dynamic> json) =>
      _$ImageDefaultsFromJson(json);
}

@freezed
abstract class ImageModelInfo with _$ImageModelInfo {
  const factory ImageModelInfo({
    @Default('') String backend,
    @Default('') String device,
    @Default(ImageCapabilities()) ImageCapabilities capabilities,
    @Default(ImageDefaults()) ImageDefaults defaults,
  }) = _ImageModelInfo;

  factory ImageModelInfo.fromJson(Map<String, dynamic> json) =>
      _$ImageModelInfoFromJson(json);
}
