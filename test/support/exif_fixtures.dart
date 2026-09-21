import 'dart:convert';
import 'dart:typed_data';

/// EXIF blocks (TIFF structures) and the JPEGs that carry them, built by
/// hand, byte by byte, so the codec is tested against what cameras write
/// rather than against itself.

List<int> ascii8(String s) => ascii.encode(s);

/// `Exif\0\0`: the header in front of the TIFF data in a JPEG APP1.
const exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

/// Entropy-coded data after SOS, then EOI: must come out byte for byte.
final scan = [0xFF, 0xDA, 0x00, 0x04, 0x01, 0x02, 0x10, 0x20, 0xFF, 0xD9];

List<int> segment(int marker, List<int> payload) => [
  0xFF,
  marker,
  (payload.length + 2) >> 8,
  (payload.length + 2) & 0xFF,
  ...payload,
];

/// A JFIF JPEG with [exif] in an APP1, then the segments [before] its
/// quantisation table, and a token scan: no decodable pixels.
Uint8List jpeg({Uint8List? exif, List<List<int>> before = const []}) =>
    Uint8List.fromList([
      0xFF, 0xD8, //
      ...segment(0xE0, [...ascii8('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
      if (exif != null) ...segment(0xE1, [...exifHeader, ...exif]),
      for (final s in before) ...s,
      ...segment(0xDB, List.filled(65, 1)),
      ...scan,
    ]);

List<int> u32be(int v) => [
  v >> 24 & 0xFF,
  v >> 16 & 0xFF,
  v >> 8 & 0xFF,
  v & 0xFF,
];
List<int> u32le(int v) => u32be(v).reversed.toList();
List<int> u16le(int v) => [v & 0xFF, v >> 8 & 0xFF];

/// One little-endian IFD entry.
typedef Entry = ({int tag, int type, int count, List<int> value});

Entry textEntry(int tag, String s) {
  final v = [...utf8.encode(s), 0];
  return (tag: tag, type: 2, count: v.length, value: v);
}

Entry short(int tag, int v) => (tag: tag, type: 3, count: 1, value: u16le(v));

Entry byte(int tag, int v) => (tag: tag, type: 1, count: 1, value: [v]);

Entry long(int tag, int v) => (tag: tag, type: 4, count: 1, value: u32le(v));

Entry undefined(int tag, List<int> v) =>
    (tag: tag, type: 7, count: v.length, value: v);

Entry rationals(int tag, List<(int, int)> values) => (
  tag: tag,
  type: 5,
  count: values.length,
  value: [
    for (final (n, d) in values) ...[...u32le(n), ...u32le(d)],
  ],
);

/// IFD0 → Exif IFD → GPS IFD, then — with a [thumbnail] — IFD1 and the
/// thumbnail's bytes at the end, as cameras lay them out.
Uint8List leTiff({
  List<Entry> ifd0 = const [],
  List<Entry> exif = const [],
  List<Entry> gps = const [],
  List<int>? thumbnail,
}) {
  int size(List<Entry> es) =>
      6 +
      12 * es.length +
      es.fold<int>(0, (n, e) => e.value.length > 4 ? n + e.value.length : n);
  Entry pointer(int tag, int at) =>
      (tag: tag, type: 4, count: 1, value: u32le(at));
  List<int> ifd(List<Entry> es, int start, [int nextIfd = 0]) {
    var next = start + 6 + 12 * es.length;
    final head = <int>[...u16le(es.length)];
    final data = <int>[];
    for (final e in es) {
      head.addAll([...u16le(e.tag), ...u16le(e.type), ...u32le(e.count)]);
      if (e.value.length <= 4) {
        head.addAll([...e.value, ...List.filled(4 - e.value.length, 0)]);
      } else {
        head.addAll(u32le(next));
        data.addAll(e.value);
        next += e.value.length;
      }
    }
    return [...head, ...u32le(nextIfd), ...data];
  }

  final ifd0Size = size([...ifd0, pointer(0, 0), pointer(0, 0)]);
  final exifAt = 8 + ifd0Size;
  final gpsAt = exifAt + size(exif);
  final fullIfd0 = [...ifd0, pointer(0x8769, exifAt), pointer(0x8825, gpsAt)];
  final ifd1At = gpsAt + size(gps);
  final ifd1 = thumbnail == null
      ? const <Entry>[]
      : [
          long(0x0201, ifd1At + size([long(0, 0), long(0, 0)])),
          long(0x0202, thumbnail.length),
        ];
  return Uint8List.fromList([
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, //
    ...ifd(fullIfd0, 8, thumbnail == null ? 0 : ifd1At),
    ...ifd(exif, exifAt),
    ...ifd(gps, gpsAt),
    if (thumbnail != null) ...[...ifd(ifd1, ifd1At), ...thumbnail],
  ]);
}

/// The EXIF of an iPhone photo: what the UI shows (`kPhotoSummary`), and
/// tags it does not show — lens, 35 mm focal length, GPS direction — that
/// travel all the same.
Uint8List iphoneTiff({int orientation = 1}) => leTiff(
  ifd0: [
    textEntry(0x010F, 'Apple'),
    textEntry(0x0110, 'iPhone 17'),
    short(0x0112, orientation),
  ],
  exif: [
    rationals(0x829A, [(1, 4329)]),
    rationals(0x829D, [(16, 10)]),
    short(0x8827, 40),
    textEntry(0x9003, '2026:07:05 19:41:50'),
    textEntry(0x9011, '+02:00'),
    rationals(0x920A, [(596, 100)]),
    short(0xA405, 26),
    textEntry(0xA433, 'Apple'),
    textEntry(0xA434, 'iPhone 17 back dual wide camera 5.96mm f/1.6'),
  ],
  gps: [
    textEntry(0x0001, 'N'),
    rationals(0x0002, [(42, 1), (34, 1), (6888, 1000)]),
    textEntry(0x0003, 'E'),
    rationals(0x0004, [(8, 1), (45, 1), (522, 100)]),
    textEntry(0x0010, 'T'),
    rationals(0x0011, [(6482, 100)]),
  ],
);
