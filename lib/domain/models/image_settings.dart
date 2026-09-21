import 'package:freezed_annotation/freezed_annotation.dart';

import 'model_info.dart';

part 'image_settings.freezed.dart';
part 'image_settings.g.dart';

/// How the image server should treat the next turn.
enum ImageMode {
  /// Let the server decide (question → answer, scene → generate, …).
  auto,
  generate,
  edit,
  chat,
}

/// Per-request options for an image-generation model.
///
/// Every field is nullable — `null` means "use the server default". The
/// whole object is only sent when the selected model is an image model
/// (`ModelInfo.isImage`), as the `generation` extension object of the
/// chat completions body.
@freezed
abstract class ImageSettings with _$ImageSettings {
  const factory ImageSettings({
    ImageMode? mode,

    /// Target side length; the output area is ≈ baseSize².
    int? baseSize,

    /// Preset such as `16:9`; `null` keeps the reference's ratio (edits) or
    /// the server default.
    String? aspectRatio,
    int? steps,

    /// `null` = a new random seed per request.
    int? seed,
    double? guidance,
    String? negativePrompt,
    bool? transparent,
  }) = _ImageSettings;

  const ImageSettings._();

  factory ImageSettings.fromJson(Map<String, dynamic> json) =>
      _$ImageSettingsFromJson(json);

  /// True when nothing overrides the server defaults.
  bool get isDefault => this == const ImageSettings();

  /// The same settings with every value that merely restates the server's
  /// [defaults] (or the "no option" meaning: `auto`, empty prompt, opaque)
  /// folded back to `null`. Keeps "is anything overridden?" and the request
  /// payload honest whatever the UI wrote.
  ImageSettings normalised(ImageDefaults defaults) => ImageSettings(
    mode: mode == ImageMode.auto ? null : mode,
    baseSize: baseSize == defaults.baseSize ? null : baseSize,
    aspectRatio: aspectRatio,
    steps: steps == defaults.steps ? null : steps,
    seed: seed,
    guidance: guidance != null && (guidance! - defaults.guidance).abs() < 0.01
        ? null
        : guidance,
    negativePrompt: negativePrompt?.isEmpty ?? false ? null : negativePrompt,
    transparent: transparent == false ? null : transparent,
  );
}
