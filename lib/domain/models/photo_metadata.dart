import 'dart:convert';
import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'photo_metadata.freezed.dart';
part 'photo_metadata.g.dart';

/// Everything the file of a photo said about it, read when the user
/// attached it so an image made from it can carry it again when saved:
/// [summary], what the UI shows, and [blocks], what is written back.
///
/// In memory only (the composer, "Annotate & reuse"). Once sent, an image
/// block keeps a [PhotoMetadataRef] and the blocks go to an attachment of
/// their own, loaded only to save or reuse the image.
@freezed
abstract class PhotoMetadata with _$PhotoMetadata {
  const factory PhotoMetadata({
    @Default(PhotoSummary()) PhotoSummary summary,
    @Default(PhotoMetadataBlocks()) PhotoMetadataBlocks blocks,
  }) = _PhotoMetadata;
}

/// Camera, date and place of a photo, read from its EXIF for display only:
/// nothing is ever written from them.
@freezed
abstract class PhotoSummary with _$PhotoSummary {
  const factory PhotoSummary({
    CameraInfo? camera,
    CaptureTime? captured,
    GeoLocation? location,
  }) = _PhotoSummary;

  factory PhotoSummary.fromJson(Map<String, dynamic> json) =>
      _$PhotoSummaryFromJson(json);
}

/// A photo's metadata blocks, verbatim — every EXIF tag including maker
/// notes, every XMP namespace, IPTC, comments — whatever system wrote
/// them, so nothing is lost to a list of known fields. Only the embedded
/// EXIF thumbnail (a picture of the original) is dropped. What describes
/// the file's own encoding rather than the photo (orientation, pixel size,
/// colour profile, multi-picture index) is never taken from here: the
/// saved file keeps its own.
///
/// Stored as an attachment of its own ([mimeType], [encode]), next to the
/// image it describes: never drawn, never sent to the model.
@freezed
abstract class PhotoMetadataBlocks with _$PhotoMetadataBlocks {
  const factory PhotoMetadataBlocks({
    /// The EXIF block (TIFF structure), base64.
    String? exif,

    /// The XMP packet.
    String? xmp,

    /// Photoshop image resources (IPTC-IIM and the rest), base64.
    String? iptc,

    /// Free-text metadata: PNG text chunks, JPEG comments.
    @Default(<PhotoText>[]) List<PhotoText> texts,
  }) = _PhotoMetadataBlocks;

  const PhotoMetadataBlocks._();

  factory PhotoMetadataBlocks.fromJson(Map<String, dynamic> json) =>
      _$PhotoMetadataBlocksFromJson(json);

  /// Type of the attachment holding the blocks.
  static const mimeType = 'application/vnd.specterchat.photo-metadata+json';

  /// The attachment's bytes.
  Uint8List encode() => utf8.encode(jsonEncode(toJson()));

  /// Inverse of [encode]; `null` when [bytes] are not such an attachment.
  static PhotoMetadataBlocks? decode(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      return json is Map<String, dynamic>
          ? PhotoMetadataBlocks.fromJson(json)
          : null;
    } on FormatException {
      return null;
    }
  }

  bool get isEmpty =>
      exif == null && xmp == null && iptc == null && texts.isEmpty;

  Uint8List? get exifBytes => exif == null ? null : base64Decode(exif!);

  Uint8List? get iptcBytes => iptc == null ? null : base64Decode(iptc!);
}

/// A photo's metadata as an image block keeps it (JSON in the message row):
/// the [summary] the UI shows, and where the [PhotoMetadataBlocks] are —
/// an attachment of the same message, [blocksId]. A message never refers
/// to another's (an image made from a photo gets a copy), so deleting a
/// message never takes another message's metadata with it.
///
/// Blocks written by earlier builds read too: the summary's fields were
/// then at the top level, and the blocks themselves, [inlineBlocks], in the
/// JSON. Those are read, never written.
@freezed
abstract class PhotoMetadataRef with _$PhotoMetadataRef {
  const factory PhotoMetadataRef({
    @JsonKey(readValue: _summaryJson)
    @Default(PhotoSummary())
    PhotoSummary summary,

    /// The attachment holding the blocks; `null` when there are none.
    String? blocksId,

    /// The blocks, when an earlier build kept them in the JSON.
    @JsonKey(readValue: _inlineBlocksJson, includeToJson: false)
    PhotoMetadataBlocks? inlineBlocks,
  }) = _PhotoMetadataRef;

  factory PhotoMetadataRef.fromJson(Map<String, dynamic> json) =>
      _$PhotoMetadataRefFromJson(json);
}

/// `summary`, or the whole object when an earlier build wrote its fields
/// at the top level.
Object? _summaryJson(Map<dynamic, dynamic> json, String key) =>
    json[key] ?? json;

/// The whole object when an earlier build wrote the blocks in it.
Object? _inlineBlocksJson(Map<dynamic, dynamic> json, String key) {
  final texts = json['texts'];
  final inline =
      json['exif'] != null ||
      json['xmp'] != null ||
      json['iptc'] != null ||
      (texts is List && texts.isNotEmpty);
  return inline ? json : null;
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

    /// Millimetres, as the lens reports it.
    double? focalLength,
    double? fNumber,

    /// Seconds.
    double? exposureTime,
    int? iso,
  }) = _CameraInfo;

  factory CameraInfo.fromJson(Map<String, dynamic> json) =>
      _$CameraInfoFromJson(json);
}

/// When the photo was taken.
@freezed
abstract class CaptureTime with _$CaptureTime {
  const factory CaptureTime({
    /// Wall-clock time where the photo was taken: a local [DateTime] with
    /// no time zone attached, never converted.
    @JsonKey(fromJson: _wallClockFromJson) required DateTime local,

    /// Offset of [local] from UTC, `+02:00`; `null` when the camera did not
    /// record it.
    String? offset,
  }) = _CaptureTime;

  factory CaptureTime.fromJson(Map<String, dynamic> json) =>
      _$CaptureTimeFromJson(json);
}

/// ISO 8601 — or EXIF's `2026:07:05 19:41:50`, the form blocks stored
/// before the date became a [DateTime] carry.
DateTime _wallClockFromJson(String s) => DateTime.parse(
  s.length > 10 && s[4] == ':' && s[7] == ':'
      ? '${s.substring(0, 4)}-${s.substring(5, 7)}-${s.substring(8)}'
      : s,
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
  }) = _GeoLocation;

  factory GeoLocation.fromJson(Map<String, dynamic> json) =>
      _$GeoLocationFromJson(json);
}

/// How a model made an image. Recorded on its block once, when the block is
/// written; "Save as…" declares it (IPTC "digital source type") when the
/// user asks for it.
enum AiOrigin {
  /// From a reference the model edited — a photo, a screenshot, an earlier
  /// result — whether or not anything is known about it (IPTC
  /// `compositeWithTrainedAlgorithmicMedia`).
  editedPhoto,

  /// From the prompt alone (IPTC `trainedAlgorithmicMedia`).
  generated,
}
