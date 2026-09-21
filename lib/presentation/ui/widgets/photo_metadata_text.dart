import '../../../application/images/image_export.dart';
import '../../../domain/models/photo_metadata.dart';

/// Human-readable renderings of [PhotoMetadata] for tooltips and the
/// "Save as…" confirmation.

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// One line per part of [m]: camera, exposure, date taken, place — or a
/// generic line when the photo's metadata says none of those.
List<String> photoMetadataLines(PhotoMetadata m) {
  final lines = [
    if (m.camera case final c?) ...[?cameraName(c), ?_exposureLine(c)],
    if (m.captured case final t?) _captureLine(t),
    if (m.location case final l?) _locationLine(l),
  ];
  return lines.isEmpty ? const ['Original photo metadata'] : lines;
}

/// A few words for a thumbnail: `iPhone 17 · 5 Jul 2026 · location`.
String photoMetadataSummary(PhotoMetadata m) {
  final parts = [
    if (m.camera case final c?) ?cameraName(c),
    if (m.captured?.localDateTime case final d?) _date(d),
    if (m.location != null) 'location',
  ];
  return parts.isEmpty ? 'photo metadata' : parts.join(' · ');
}

/// The confirmation after "Save as…", or `null` when nothing was written
/// into the file.
String? savedMetadataMessage(ImageExport export) =>
    switch ((export.keptOriginal, export.markedAiEdited)) {
      (true, false) => "Saved with the original photo's metadata",
      (true, true) =>
        "Saved with the original photo's metadata, marked as AI-generated",
      (false, true) => 'Saved, marked as AI-generated',
      (false, false) => null,
    };

/// The camera as a label: its model (which usually names the brand too),
/// else its make.
String? cameraName(CameraInfo c) => c.model ?? c.make;

String? _exposureLine(CameraInfo c) {
  final parts = [
    if (c.focalLength case final f?) '${_number(f)} mm',
    if (c.fNumber case final n?) 'f/${_number(n)}',
    if (c.exposureTime case final t?)
      t >= 1 ? '${_number(t)} s' : '1/${(1 / t).round()} s',
    if (c.iso case final iso?) 'ISO $iso',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _captureLine(CaptureTime t) {
  final d = t.localDateTime;
  if (d == null) return t.local;
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  final offset = t.offset == null ? '' : ' (UTC${t.offset})';
  return '${_date(d)}, $hh:$mm$offset';
}

String _locationLine(GeoLocation l) {
  final altitude = l.altitude == null ? '' : ' · ${l.altitude!.round()} m';
  return '${_coordinate(l.latitude, 'N', 'S')}, '
      '${_coordinate(l.longitude, 'E', 'W')}$altitude';
}

String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String _coordinate(double v, String positive, String negative) =>
    '${v.abs().toStringAsFixed(5)}° ${v < 0 ? negative : positive}';

final _trailingZeros = RegExp(r'\.?0+$');

/// Up to two decimals, trailing zeros dropped: `5.96`, `1.6`, `50`.
String _number(double v) =>
    v.toStringAsFixed(2).replaceFirst(_trailingZeros, '');
