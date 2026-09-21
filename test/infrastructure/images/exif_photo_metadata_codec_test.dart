import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/infrastructure/images/exif_photo_metadata_codec.dart';

const codec = ExifPhotoMetadataCodec();

const iphone = PhotoMetadata(
  camera: CameraInfo(
    make: 'Apple',
    model: 'iPhone 17',
    lensMake: 'Apple',
    lensModel: 'iPhone 17 back dual wide camera 5.96mm f/1.6',
    focalLength: 5.96,
    focalLength35mm: 26,
    fNumber: 1.6,
    exposureTime: 1 / 4329,
    iso: 40,
  ),
  captured: CaptureTime(local: '2026:07:05 19:41:50', offset: '+02:00'),
  location: GeoLocation(
    latitude: 42.56858,
    longitude: 8.75145,
    altitude: 33.97,
    direction: 64.82,
  ),
);

void main() {
  group('read', () {
    test('a little-endian EXIF block, as many cameras write it', () {
      final metadata = codec.read(jpeg(exif: canonTiff()));

      expect(
        metadata?.camera,
        const CameraInfo(
          make: 'Canon',
          model: 'EOS R5',
          focalLength: 50,
          fNumber: 2.8,
          exposureTime: 1 / 250,
          iso: 100,
        ),
      );
      expect(
        metadata?.captured,
        const CaptureTime(local: '2024:05:01 10:20:30', offset: '-04:00'),
      );
      final location = metadata!.location!;
      // South and west are negative; the altitude is below sea level.
      expect(location.latitude, closeTo(-(33 + 51 / 60 + 30.84 / 3600), 1e-8));
      expect(location.longitude, closeTo(-151.21, 1e-8));
      expect(location.altitude, -5);
      expect(location.direction, 270);
      expect(location.magneticNorth, isTrue);
    });

    test('drops what a camera without clock or fix writes', () {
      final tiff = leTiff(
        ifd0: [textEntry(0x010F, 'Canon')],
        exif: [textEntry(0x9003, '0000:00:00 00:00:00')],
        gps: [
          textEntry(0x0001, 'N'),
          rationals(0x0002, [(0, 1), (0, 1), (0, 1)]),
          textEntry(0x0003, 'E'),
          rationals(0x0004, [(0, 1), (0, 1), (0, 1)]),
        ],
      );
      final read = codec.read(jpeg(exif: tiff))!;
      expect(read.camera, const CameraInfo(make: 'Canon'));
      expect(read.captured, isNull);
      expect(read.location, isNull);
    });

    test('from PNG eXIf and WebP EXIF chunks, with or without header', () {
      final tiff = canonTiff();
      final withHeader = Uint8List.fromList([...exifHeader, ...tiff]);
      for (final bytes in [
        png(extra: [chunk('eXIf', tiff)]),
        png(extra: [chunk('eXIf', withHeader)]),
        webp(exif: tiff),
        webp(exif: withHeader),
      ]) {
        expect(codec.read(bytes)?.camera?.model, 'EOS R5');
      }
    });

    test('is null, never a throw, when there is nothing usable', () {
      final broken = Uint8List.fromList(canonTiff())
        ..setRange(4, 8, [0xFF, 0xFF, 0x00, 0x00]); // IFD0 out of bounds
      for (final bytes in [
        jpeg(),
        png(),
        jpeg(exif: broken),
        jpeg(exif: Uint8List.fromList([1, 2, 3])),
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x00]), // truncated
        Uint8List.fromList(ascii8('GIF89a')),
        Uint8List.fromList([1, 2, 3]),
      ]) {
        expect(codec.read(bytes), isNull);
      }
    });
  });

  group('write', () {
    test('round-trips through JPEG and PNG', () {
      for (final target in [jpeg(), png()]) {
        final written = codec.write(target, iphone)!;
        final read = codec.read(written)!;

        expect(read.camera, iphone.camera);
        expect(read.captured, iphone.captured);
        expect(read.location!.latitude, 42.56858);
        expect(read.location!.longitude, 8.75145);
        expect(read.location!.altitude, closeTo(33.97, 1e-9));
        expect(read.location!.direction, closeTo(64.82, 1e-9));
      }
    });

    test('rebuilds EXIF from display fields alone (earlier versions)', () {
      const dateOnly = PhotoMetadata(
        captured: CaptureTime(local: '2026:07:05 19:41:50'),
      );
      final read = codec.read(codec.write(png(), dateOnly)!)!;
      expect(read.captured, dateOnly.captured);
      expect(read.camera, isNull);
      expect(read.location, isNull);
    });

    test('PNG: EXIF right after IHDR, old metadata out, the file kept', () {
      final idat = chunk('IDAT', [1, 2, 3, 4, 5]);
      final iccp = chunk('iCCP', [...ascii8('P3'), 0, 0, 9, 9]);
      final comment = chunk('tEXt', [...ascii8('Comment'), 0, ...ascii8('hi')]);
      final source = png(
        extra: [
          chunk('eXIf', canonTiff()),
          iccp,
          chunk('iTXt', [...ascii8('XML:com.adobe.xmp'), 0, 0, 0, 0, 0, 1]),
          comment,
          idat,
        ],
      );

      final written = codec.write(source, iphone)!;

      final chunks = pngChunks(written);
      // The file's own text is metadata too: replaced like the rest.
      expect(chunks.map((c) => c.type), [
        'IHDR',
        'eXIf',
        'iCCP',
        'IDAT',
        'IEND',
      ]);
      for (final c in chunks) {
        expect(c.crcValid, isTrue, reason: '${c.type} CRC');
      }
      expect(chunks[2].raw, iccp);
      expect(chunks[3].raw, idat);
    });

    test(
      'JPEG: EXIF after APP0, old APP1/APP13 out, profile and scan kept',
      () {
        final app2 = segment(0xE2, [...ascii8('ICC_PROFILE'), 0, 1, 1, 7, 7]);
        final app13 = segment(0xED, ascii8('Photoshop 3.0'));
        final xmp = segment(0xE1, [
          ...ascii8('http://ns.adobe.com/xap/1.0/'),
          0,
        ]);
        final source = jpeg(exif: canonTiff(), before: [xmp, app13, app2]);

        final written = codec.write(source, iphone)!;

        final markers = jpegMarkers(written);
        expect(markers, [0xE0, 0xE1, 0xE2, 0xDB, 0xDA]);
        expect(containsBytes(written, app2), isTrue);
        expect(containsBytes(written, ascii8('Photoshop')), isFalse);
        expect(written.sublist(written.length - scan.length), scan);
      },
    );

    test("keeps the file's own orientation, never the photo's", () {
      // A JPEG attached untouched still stores its pixels sideways.
      final sideways = leTiff(ifd0: [short(0x0112, 6)]);
      final kept = codec.write(jpeg(exif: sideways), iphone)!;
      expect(tiffInteger(exifOfJpeg(kept)!, 0x0112), 6);

      // A generated image has none: none is invented.
      final generated = codec.write(png(), iphone)!;
      expect(tiffInteger(exifOfPng(generated)!, 0x0112), isNull);
    });

    test('with nothing to write, strips the old metadata', () {
      final written = codec.write(
        jpeg(exif: canonTiff()),
        const PhotoMetadata(),
      )!;
      expect(jpegMarkers(written), [0xE0, 0xDB, 0xDA]);
    });

    test('declares AI only when asked', () {
      final plain = codec.write(png(), iphone)!;
      expect(containsBytes(plain, ascii8('SpecterChat')), isFalse);
      expect(containsBytes(plain, ascii8('xmp')), isFalse);

      final edited = codec.write(
        png(),
        iphone,
        aiMark: AiEditMark.editedPhoto,
      )!;
      expect(xmpOf(edited), contains('compositeWithTrainedAlgorithmicMedia'));
      expect(xmpOf(edited), contains('xmp:CreatorTool="SpecterChat"'));
      expect(pngChunks(edited).every((c) => c.crcValid), isTrue);

      final generated = codec.write(
        jpeg(),
        const PhotoMetadata(),
        aiMark: AiEditMark.generated,
      )!;
      expect(xmpOf(generated), contains('/trainedAlgorithmicMedia"'));
    });

    test('is null for formats it does not splice into', () {
      expect(codec.write(webp(exif: canonTiff()), iphone), isNull);
      expect(codec.write(png().sublist(0, 20), iphone), isNull);
    });
  });

  group('the original, verbatim', () {
    test(
      'every EXIF tag, maker notes and unknown ones, minus the thumbnail',
      () {
        final makerNote = ascii8('Apple iOS maker note, opaque');
        final future = ascii8('a tag nobody knows yet');
        final thumbnail = [0xFF, 0xD8, ...ascii8('OLD PICTURE'), 0xFF, 0xD9];
        final source = leTiff(
          ifd0: [textEntry(0x0110, 'iPhone 17'), short(0x0112, 6)],
          exif: [
            undefined(0x927C, makerNote),
            undefined(0x9999, future),
            long(0xA002, 4032),
            long(0xA003, 3024),
          ],
          thumbnail: thumbnail,
        );

        final read = codec.read(jpeg(exif: source))!;
        final kept = read.exifBytes!;
        expect(containsBytes(kept, makerNote), isTrue);
        expect(containsBytes(kept, future), isTrue);
        expect(containsBytes(kept, ascii8('OLD PICTURE')), isFalse);
        expect(nextIfdOf(kept), 0);

        // Into a 1×1 generated PNG: upright, its own size, the rest as read.
        final written = exifOfPng(codec.write(png(), read)!)!;
        expect(containsBytes(written, makerNote), isTrue);
        expect(containsBytes(written, future), isTrue);
        expect(tiffInteger(written, 0x0112), 1);
        expect(tiffInteger(written, 0xA002, inExifIfd: true), 1);
        expect(tiffInteger(written, 0xA003, inExifIfd: true), 1);
        expect(codec.read(written.asPng)?.camera?.model, 'iPhone 17');

        // Into a file stored sideways: its orientation stays its own.
        final sideways = jpeg(exif: leTiff(ifd0: [short(0x0112, 6)]));
        final intoSideways = exifOfJpeg(codec.write(sideways, read)!)!;
        expect(tiffInteger(intoSideways, 0x0112), 6);
        expect(containsBytes(intoSideways, future), isTrue);
      },
    );

    test('the XMP packet, any namespace, padding trimmed', () {
      final packet = xmpPacket(
        'xmlns:tiff="http://ns.adobe.com/tiff/1.0/" tiff:Orientation="6" '
        'xmlns:future="http://example.com/future/1.0/" '
        'future:Scene="kept"',
      );
      final read = codec.read(
        jpeg(
          before: [
            segment(0xE1, [...xmpHeader, ...utf8.encode(packet)]),
          ],
        ),
      )!;
      expect(read.xmp, contains('future:Scene="kept"'));
      expect(read.xmp!.length, lessThan(packet.length - 1000));

      final written = codec.write(png(), read)!;
      expect(xmpOf(written), contains('future:Scene="kept"'));
      expect(xmpOf(written), contains('tiff:Orientation="1"'));
    });

    test('the AI mark updates an existing declaration, else adds one', () {
      const capture =
          'http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture';
      final declared = PhotoMetadata(
        xmp: xmpPacket(
          'xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" '
          'Iptc4xmpExt:DigitalSourceType="$capture"',
        ),
      );
      final updated = xmpOf(
        codec.write(png(), declared, aiMark: AiEditMark.editedPhoto)!,
      )!;
      expect(updated, isNot(contains(capture)));
      expect(
        'DigitalSourceType='.allMatches(updated),
        hasLength(1),
        reason: updated,
      );
      expect(updated, contains('compositeWithTrainedAlgorithmicMedia'));

      final other = PhotoMetadata(
        xmp: xmpPacket('xmlns:dc="http://purl.org/dc/elements/1.1/"'),
      );
      final added = xmpOf(
        codec.write(png(), other, aiMark: AiEditMark.editedPhoto)!,
      )!;
      expect(added, contains('xmlns:dc='));
      expect(added, contains('compositeWithTrainedAlgorithmicMedia'));
      // Without the mark, the photo's own declaration is left alone.
      expect(xmpOf(codec.write(png(), declared)!), contains(capture));
    });

    test('Photoshop resources (IPTC), thumbnails out, JPEG and PNG', () {
      final iptc = resource(0x0404, [
        0x1C,
        0x02,
        0x6E,
        0,
        5,
        ...ascii8('Yoann'),
      ]);
      final thumbnail = resource(0x040C, ascii8('OLD PICTURE'));
      final read = codec.read(
        jpeg(
          before: [
            segment(0xED, [...photoshopHeader, ...iptc, ...thumbnail]),
          ],
        ),
      )!;
      expect(read.iptcBytes, iptc);

      final intoJpeg = codec.write(jpeg(), read)!;
      expect(containsBytes(intoJpeg, [...photoshopHeader, ...iptc]), isTrue);
      expect(containsBytes(intoJpeg, ascii8('OLD PICTURE')), isFalse);

      final intoPng = codec.write(png(), read)!;
      final profile = pngChunks(
        intoPng,
      ).singleWhere((c) => c.type == 'tEXt').raw;
      expect(containsBytes(profile, ascii8('Raw profile type 8bim')), isTrue);
      expect(containsBytes(profile, ascii8(hex(iptc))), isTrue);
    });

    test('PNG text chunks and JPEG comments, across formats', () {
      final source = png(
        extra: [
          chunk('tEXt', [...ascii8('Title'), 0, ...ascii8('Calvi')]),
          chunk('zTXt', [
            ...ascii8('Description'),
            0,
            0,
            ...zlib.encode(latin1.encode('Coucher de soleil')),
          ]),
          chunk('iTXt', [
            ...ascii8('Author'),
            0,
            0,
            0,
            ...ascii8('fr'),
            0,
            0,
            ...utf8.encode('Élodie'),
          ]),
          chunk('IDAT', [9, 9]),
        ],
      );
      const texts = [
        PhotoText(keyword: 'Title', text: 'Calvi'),
        PhotoText(keyword: 'Description', text: 'Coucher de soleil'),
        PhotoText(keyword: 'Author', text: 'Élodie'),
      ];
      final read = codec.read(source)!;
      expect(read.texts, texts);

      expect(codec.read(codec.write(png(), read)!)!.texts, texts);

      final intoJpeg = codec.write(jpeg(), read)!;
      expect(codec.read(intoJpeg)!.texts, const [
        PhotoText(keyword: 'Comment', text: 'Title: Calvi'),
        PhotoText(keyword: 'Comment', text: 'Description: Coucher de soleil'),
        PhotoText(keyword: 'Comment', text: 'Author: Élodie'),
      ]);
    });

    test("what describes the photo's file is not brought along", () {
      final source = jpeg(
        exif: canonTiff(),
        before: [
          segment(0xE2, [...ascii8('ICC_PROFILE'), 0, 1, 1, ...ascii8('P3')]),
          segment(0xE2, [...ascii8('MPF'), 0, 1, 2, 3]),
          segment(0xEA, [...ascii8('AROT'), 0, 7, 7]),
        ],
      );
      final written = codec.write(png(), codec.read(source)!)!;
      for (final marker in ['ICC_PROFILE', 'MPF', 'AROT']) {
        expect(containsBytes(written, ascii8(marker)), isFalse, reason: marker);
      }
      expect(codec.read(written)?.camera?.model, 'EOS R5');
    });
  });
}

// =====================================================================
// Fixtures: containers and a little-endian TIFF, built by hand
// =====================================================================

const exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

List<int> ascii8(String s) => ascii.encode(s);

extension on Uint8List {
  /// This TIFF structure as the EXIF of a PNG.
  Uint8List get asPng => png(extra: [chunk('eXIf', this)]);
}

final xmpHeader = [...ascii8('http://ns.adobe.com/xap/1.0/'), 0];
final photoshopHeader = [...ascii8('Photoshop 3.0'), 0];

/// An XMP packet with one description carrying [attributes], padded the
/// way writers reserve room for in-place edits.
String xmpPacket(String attributes) =>
    '<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
    '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    '<rdf:Description rdf:about="" $attributes/>'
    '</rdf:RDF></x:xmpmeta>${' ' * 2000}<?xpacket end="w"?>';

/// One Photoshop image resource, unnamed.
List<int> resource(int id, List<int> data) => [
  ...ascii8('8BIM'),
  id >> 8,
  id & 0xFF,
  0,
  0,
  ...u32be(data.length),
  ...data,
  if (data.length.isOdd) 0,
];

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Entropy-coded data after SOS, then EOI: must come out byte for byte.
final scan = [0xFF, 0xDA, 0x00, 0x04, 0x01, 0x02, 0x10, 0x20, 0xFF, 0xD9];

List<int> segment(int marker, List<int> payload) => [
  0xFF,
  marker,
  (payload.length + 2) >> 8,
  (payload.length + 2) & 0xFF,
  ...payload,
];

Uint8List jpeg({Uint8List? exif, List<List<int>> before = const []}) =>
    Uint8List.fromList([
      0xFF, 0xD8, //
      ...segment(0xE0, [...ascii8('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
      if (exif != null) ...segment(0xE1, [...exifHeader, ...exif]),
      for (final s in before) ...s,
      ...segment(0xDB, List.filled(65, 1)),
      ...scan,
    ]);

List<int> chunk(String type, List<int> data) {
  final body = [...ascii8(type), ...data];
  final crc = crc32(body);
  return [...u32be(data.length), ...body, ...u32be(crc)];
}

Uint8List png({List<List<int>> extra = const []}) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ...chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]),
  for (final c in extra) ...c,
  if (extra.isEmpty) ...chunk('IDAT', [9, 9]),
  ...chunk('IEND', const []),
]);

Uint8List webp({required Uint8List exif}) {
  final vp8x = [...ascii8('VP8X'), ...u32le(10), 0x08, ...List.filled(9, 0)];
  final exifChunk = [
    ...ascii8('EXIF'),
    ...u32le(exif.length),
    ...exif,
    if (exif.length.isOdd) 0,
  ];
  final body = [...ascii8('WEBP'), ...vp8x, ...exifChunk];
  return Uint8List.fromList([
    ...ascii8('RIFF'),
    ...u32le(body.length),
    ...body,
  ]);
}

List<int> u32be(int v) => [
  v >> 24 & 0xFF,
  v >> 16 & 0xFF,
  v >> 8 & 0xFF,
  v & 0xFF,
];
List<int> u32le(int v) => u32be(v).reversed.toList();
List<int> u16le(int v) => [v & 0xFF, v >> 8 & 0xFF];

/// Bitwise CRC-32 — deliberately not the codec's table-driven one.
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c >> 1) ^ (0xEDB88320 & -(c & 1));
    }
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

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

Uint8List canonTiff() => leTiff(
  ifd0: [
    textEntry(0x010F, 'Canon'),
    textEntry(0x0110, 'EOS R5'),
    short(0x0112, 1),
  ],
  exif: [
    rationals(0x829A, [(1, 250)]),
    rationals(0x829D, [(28, 10)]),
    short(0x8827, 100),
    textEntry(0x9003, '2024:05:01 10:20:30'),
    textEntry(0x9011, '-04:00'),
    rationals(0x920A, [(50, 1)]),
  ],
  gps: [
    textEntry(0x0001, 'S'),
    rationals(0x0002, [(33, 1), (51, 1), (3084, 100)]),
    textEntry(0x0003, 'W'),
    rationals(0x0004, [(151, 1), (12, 1), (3600, 100)]),
    byte(0x0005, 1),
    rationals(0x0006, [(5, 1)]),
    textEntry(0x0010, 'M'),
    rationals(0x0011, [(270, 1)]),
  ],
);

// =====================================================================
// Inspecting what came out
// =====================================================================

typedef PngChunk = ({String type, List<int> raw, bool crcValid});

List<PngChunk> pngChunks(Uint8List b) {
  final view = ByteData.sublistView(b);
  final out = <PngChunk>[];
  var i = 8;
  while (i < b.length) {
    final length = view.getUint32(i);
    final end = i + 12 + length;
    final raw = b.sublist(i, end);
    out.add((
      type: ascii.decode(b.sublist(i + 4, i + 8)),
      raw: raw,
      crcValid: view.getUint32(end - 4) == crc32(b.sublist(i + 4, end - 4)),
    ));
    i = end;
  }
  return out;
}

/// Markers of the segments up to and including SOS.
List<int> jpegMarkers(Uint8List b) {
  final out = <int>[];
  var i = 2;
  while (i < b.length) {
    final marker = b[i + 1];
    out.add(marker);
    if (marker == 0xDA) return out;
    i += 2 + (b[i + 2] << 8 | b[i + 3]);
  }
  return out;
}

bool containsBytes(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (haystack[i + k] != needle[k]) continue outer;
    }
    return true;
  }
  return false;
}

String? xmpOf(Uint8List b) {
  final text = latin1.decode(b);
  final start = text.indexOf('<x:xmpmeta');
  final end = text.indexOf('</x:xmpmeta>');
  return start < 0 || end < 0 ? null : text.substring(start, end);
}

/// The TIFF structure of a PNG's `eXIf` chunk.
Uint8List? exifOfPng(Uint8List b) {
  for (final c in pngChunks(b)) {
    if (c.type == 'eXIf') {
      return Uint8List.fromList(c.raw.sublist(8, c.raw.length - 4));
    }
  }
  return null;
}

/// The TIFF structure of a JPEG's EXIF APP1.
Uint8List? exifOfJpeg(Uint8List b) {
  var i = 2;
  while (i + 4 <= b.length && b[i + 1] != 0xDA) {
    final end = i + 2 + (b[i + 2] << 8 | b[i + 3]);
    if (b[i + 1] == 0xE1 &&
        containsBytes(b.sublist(i + 4, i + 10), exifHeader)) {
      return b.sublist(i + 10, end);
    }
    i = end;
  }
  return null;
}

/// A SHORT or LONG value of IFD0 — or of the Exif IFD — either byte order.
int? tiffInteger(Uint8List tiff, int tag, {bool inExifIfd = false}) {
  final view = ByteData.sublistView(tiff);
  final endian = tiff[0] == 0x49 ? Endian.little : Endian.big;
  int? find(int ifd, int wanted) {
    for (var k = 0; k < view.getUint16(ifd, endian); k++) {
      final e = ifd + 2 + 12 * k;
      if (view.getUint16(e, endian) != wanted) continue;
      return view.getUint16(e + 2, endian) == 3
          ? view.getUint16(e + 8, endian)
          : view.getUint32(e + 8, endian);
    }
    return null;
  }

  final ifd0 = view.getUint32(4, endian);
  if (!inExifIfd) return find(ifd0, tag);
  final exif = find(ifd0, 0x8769);
  return exif == null ? null : find(exif, tag);
}

/// IFD0's link to the next IFD (the thumbnail's, when there is one).
int nextIfdOf(Uint8List tiff) {
  final view = ByteData.sublistView(tiff);
  final endian = tiff[0] == 0x49 ? Endian.little : Endian.big;
  final ifd0 = view.getUint32(4, endian);
  return view.getUint32(ifd0 + 2 + 12 * view.getUint16(ifd0, endian), endian);
}
