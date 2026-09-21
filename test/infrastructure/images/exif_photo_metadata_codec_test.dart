import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/infrastructure/images/exif_photo_metadata_codec.dart';

import '../../support/exif_fixtures.dart';

const codec = ExifPhotoMetadataCodec();

/// What reading an iPhone photo yields: display fields and the EXIF block.
final iphone = codec.read(jpeg(exif: iphoneTiff()))!;

void main() {
  group('read', () {
    test('a little-endian EXIF block, as many cameras write it', () {
      final metadata = codec.read(jpeg(exif: canonTiff()));

      expect(
        metadata?.summary.camera,
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
        metadata?.summary.captured,
        CaptureTime(local: DateTime(2024, 5, 1, 10, 20, 30), offset: '-04:00'),
      );
      final location = metadata!.summary.location!;
      // South and west are negative; the altitude is below sea level.
      expect(location.latitude, closeTo(-(33 + 51 / 60 + 30.84 / 3600), 1e-8));
      expect(location.longitude, closeTo(-151.21, 1e-8));
      expect(location.altitude, -5);
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
      expect(read.summary.camera, const CameraInfo(make: 'Canon'));
      expect(read.summary.captured, isNull);
      expect(read.summary.location, isNull);
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
        expect(codec.read(bytes)?.summary.camera?.model, 'EOS R5');
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
        // Display fields and the EXIF block, byte for byte.
        expect(codec.read(codec.write(target, iphone.blocks)!), iphone);
      }
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

      final written = codec.write(source, iphone.blocks)!;

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

        final written = codec.write(source, iphone.blocks)!;

        final markers = jpegMarkers(written);
        expect(markers, [0xE0, 0xE1, 0xE2, 0xDB, 0xDA]);
        expect(containsBytes(written, app2), isTrue);
        expect(containsBytes(written, ascii8('Photoshop')), isFalse);
        expect(written.sublist(written.length - scan.length), scan);
      },
    );

    test("keeps the file's own orientation, never the photo's", () {
      // A JPEG attached untouched still stores its pixels sideways.
      final sideways = jpeg(exif: leTiff(ifd0: [short(0x0112, 6)]));
      expect(
        tiffInteger(exifOfJpeg(codec.write(sideways, iphone.blocks)!)!, 0x0112),
        6,
      );

      // A generated image is upright, whatever the photo said.
      final sidewaysPhoto = codec.read(jpeg(exif: iphoneTiff(orientation: 6)))!;
      final generated = codec.write(png(), sidewaysPhoto.blocks)!;
      expect(tiffInteger(exifOfPng(generated)!, 0x0112), 1);
    });

    test('a file stored sideways says so even with no EXIF to write', () {
      final sideways = jpeg(
        exif: leTiff(ifd0: [textEntry(0x0110, 'iPhone 17'), short(0x0112, 8)]),
      );
      final exif = exifOfJpeg(
        codec.write(sideways, const PhotoMetadataBlocks())!,
      )!;
      expect(tiffInteger(exif, 0x0112), 8);
      // Its orientation and nothing else: no Exif IFD, no camera.
      expect(exif, hasLength(26));
      expect(codec.read(exif.asPng)!.summary.camera, isNull);
    });

    test('with nothing to write, strips the old metadata', () {
      final written = codec.write(
        jpeg(exif: canonTiff()),
        const PhotoMetadataBlocks(),
      )!;
      expect(jpegMarkers(written), [0xE0, 0xDB, 0xDA]);
    });

    test('declares AI only when asked', () {
      final plain = codec.write(png(), iphone.blocks)!;
      expect(containsBytes(plain, ascii8('SpecterChat')), isFalse);
      expect(containsBytes(plain, ascii8('xmp')), isFalse);

      final edited = codec.write(
        png(),
        iphone.blocks,
        aiMark: AiOrigin.editedPhoto,
      )!;
      expect(xmpOf(edited), contains('compositeWithTrainedAlgorithmicMedia'));
      expect(xmpOf(edited), contains('xmp:CreatorTool="SpecterChat"'));
      expect(pngChunks(edited).every((c) => c.crcValid), isTrue);

      final generated = codec.write(
        jpeg(),
        const PhotoMetadataBlocks(),
        aiMark: AiOrigin.generated,
      )!;
      expect(xmpOf(generated), contains('/trainedAlgorithmicMedia"'));
    });

    test('is null for formats it does not splice into', () {
      expect(codec.write(webp(exif: canonTiff()), iphone.blocks), isNull);
      expect(codec.write(png().sublist(0, 20), iphone.blocks), isNull);
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
        final kept = read.blocks.exifBytes!;
        expect(containsBytes(kept, makerNote), isTrue);
        expect(containsBytes(kept, future), isTrue);
        expect(containsBytes(kept, ascii8('OLD PICTURE')), isFalse);
        expect(nextIfdOf(kept), 0);

        // Into a 1×1 generated PNG: upright, its own size, the rest as read.
        final written = exifOfPng(codec.write(png(), read.blocks)!)!;
        expect(containsBytes(written, makerNote), isTrue);
        expect(containsBytes(written, future), isTrue);
        expect(tiffInteger(written, 0x0112), 1);
        expect(tiffInteger(written, 0xA002, inExifIfd: true), 1);
        expect(tiffInteger(written, 0xA003, inExifIfd: true), 1);
        expect(codec.read(written.asPng)?.summary.camera?.model, 'iPhone 17');

        // Into a file stored sideways: its orientation stays its own.
        final sideways = jpeg(exif: leTiff(ifd0: [short(0x0112, 6)]));
        final intoSideways = exifOfJpeg(codec.write(sideways, read.blocks)!)!;
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
      expect(read.blocks.xmp, contains('future:Scene="kept"'));
      expect(read.blocks.xmp!.length, lessThan(packet.length - 1000));

      final written = codec.write(png(), read.blocks)!;
      expect(xmpOf(written), contains('future:Scene="kept"'));
      expect(xmpOf(written), contains('tiff:Orientation="1"'));
    });

    test('the AI mark updates an existing declaration, else adds one', () {
      const capture =
          'http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture';
      final declared = PhotoMetadataBlocks(
        xmp: xmpPacket(
          'xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" '
          'Iptc4xmpExt:DigitalSourceType="$capture"',
        ),
      );
      final updated = xmpOf(
        codec.write(png(), declared, aiMark: AiOrigin.editedPhoto)!,
      )!;
      expect(updated, isNot(contains(capture)));
      expect(
        'DigitalSourceType='.allMatches(updated),
        hasLength(1),
        reason: updated,
      );
      expect(updated, contains('compositeWithTrainedAlgorithmicMedia'));

      final other = PhotoMetadataBlocks(
        xmp: xmpPacket('xmlns:dc="http://purl.org/dc/elements/1.1/"'),
      );
      final added = xmpOf(
        codec.write(png(), other, aiMark: AiOrigin.editedPhoto)!,
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
      expect(read.blocks.iptcBytes, iptc);

      final intoJpeg = codec.write(jpeg(), read.blocks)!;
      expect(containsBytes(intoJpeg, [...photoshopHeader, ...iptc]), isTrue);
      expect(containsBytes(intoJpeg, ascii8('OLD PICTURE')), isFalse);

      final intoPng = codec.write(png(), read.blocks)!;
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
      expect(read.blocks.texts, texts);

      expect(codec.read(codec.write(png(), read.blocks)!)!.blocks.texts, texts);

      final intoJpeg = codec.write(jpeg(), read.blocks)!;
      expect(codec.read(intoJpeg)!.blocks.texts, const [
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
      final written = codec.write(png(), codec.read(source)!.blocks)!;
      for (final marker in ['ICC_PROFILE', 'MPF', 'AROT']) {
        expect(containsBytes(written, ascii8(marker)), isFalse, reason: marker);
      }
      expect(codec.read(written)?.summary.camera?.model, 'EOS R5');
    });
  });
}

// =====================================================================
// Fixtures: containers and a little-endian TIFF, built by hand
// =====================================================================

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
