import 'dart:convert';
import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'photo_metadata.freezed.dart';
part 'photo_metadata.g.dart';

/// Everything the file of a photo said about it, read when the user
/// attached it so an image made from it can carry it again when saved.
///
/// The metadata blocks are kept verbatim — every EXIF tag including maker
/// notes, every XMP namespace, IPTC, comments — whatever system wrote
/// them, so nothing is lost to a list of known fields. Only the embedded
/// EXIF thumbnail (a picture of the original) is dropped. What describes
/// the file's own encoding rather than the photo (orientation, pixel size,
/// colour profile, multi-picture index) is never taken from here: the
/// saved file keeps its own.
///
/// [camera], [captured] and [location] are read from the blocks for
/// display. Images attached by an earlier version carry only those, and
/// are saved with an EXIF block rebuilt from them.
@freezed
abstract class PhotoMetadata with _$PhotoMetadata {
  const factory PhotoMetadata({
    CameraInfo? camera,
    CaptureTime? captured,
    GeoLocation? location,

    /// The EXIF block (TIFF structure), base64.
    String? exif,

    /// The XMP packet.
    String? xmp,

    /// Photoshop image resources (IPTC-IIM and the rest), base64.
    String? iptc,

    /// Free-text metadata: PNG text chunks, JPEG comments.
    @Default(<PhotoText>[]) List<PhotoText> texts,
  }) = _PhotoMetadata;

  const PhotoMetadata._();

  factory PhotoMetadata.fromJson(Map<String, dynamic> json) =>
      _$PhotoMetadataFromJson(json);

  bool get isEmpty =>
      camera == null &&
      captured == null &&
      location == null &&
      exif == null &&
      xmp == null &&
      iptc == null &&
      texts.isEmpty;

  Uint8List? get exifBytes => exif == null ? null : base64Decode(exif!);

  Uint8List? get iptcBytes => iptc == null ? null : base64Decode(iptc!);
}

/// One free-text entry: a PNG `tEXt` / `zTXt` / `iTXt` chunk, or a JPEG
/// comment (keyword `Comment`).
@freezed
abstract class PhotoText with _$PhotoText {
  const factory PhotoText({required String keyword, required String text}) =
      _PhotoText;

  factory PhotoText.fromJson(Map<String, dynamic> json) =>
      _$PhotoTextFromJson(json);
}

/// The device and the exposure of the original shot (for display).
@freezed
abstract class CameraInfo with _$CameraInfo {
  const factory CameraInfo({
    String? make,
    String? model,
    String? lensMake,
    String? lensModel,

    /// Millimetres, as the lens reports it.
    double? focalLength,
    int? focalLength35mm,
    double? fNumber,

    /// Seconds.
    double? exposureTime,
    int? iso,
  }) = _CameraInfo;

  factory CameraInfo.fromJson(Map<String, dynamic> json) =>
      _$CameraInfoFromJson(json);
}

/// When the photo was taken, kept in EXIF's own shape so it is written
/// back exactly as read.
@freezed
abstract class CaptureTime with _$CaptureTime {
  const factory CaptureTime({
    /// Wall-clock time where the photo was taken, `YYYY:MM:DD HH:MM:SS`.
    required String local,

    /// Offset of [local] from UTC, `+02:00`; `null` when the camera did not
    /// record it.
    String? offset,
  }) = _CaptureTime;

  const CaptureTime._();

  factory CaptureTime.fromJson(Map<String, dynamic> json) =>
      _$CaptureTimeFromJson(json);

  /// [local] as a [DateTime] (no time zone attached), or `null` when it is
  /// not in the EXIF shape.
  DateTime? get localDateTime {
    final m = _exifDateTime.firstMatch(local);
    if (m == null) return null;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
    return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  }
}

final _exifDateTime = RegExp(
  r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
);

/// Where the photo was taken.
@freezed
abstract class GeoLocation with _$GeoLocation {
  const factory GeoLocation({
    /// Degrees, negative south of the equator.
    required double latitude,

    /// Degrees, negative west of Greenwich.
    required double longitude,

    /// Metres, negative below sea level.
    double? altitude,

    /// Degrees clockwise from north: where the camera was pointing.
    double? direction,

    /// [direction] is relative to magnetic north rather than true north.
    @Default(false) bool magneticNorth,
  }) = _GeoLocation;

  factory GeoLocation.fromJson(Map<String, dynamic> json) =>
      _$GeoLocationFromJson(json);
}

/// How a saved image declares that a model made it (IPTC "digital source
/// type"), when the user asks for it.
enum AiEditMark {
  /// A photo edited by the model (IPTC
  /// `compositeWithTrainedAlgorithmicMedia`).
  editedPhoto,

  /// An image the model generated from the prompt alone (IPTC
  /// `trainedAlgorithmicMedia`).
  generated,
}
