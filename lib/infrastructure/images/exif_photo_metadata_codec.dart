import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/app_info.dart';
import '../../core/image_mime.dart';
import '../../domain/models/photo_metadata.dart';
import '../../domain/services/i_photo_metadata_codec.dart';

/// [IPhotoMetadataCodec] in pure Dart, so it behaves the same on every
/// desktop.
///
/// Reading keeps a photo's metadata blocks verbatim, from JPEG, PNG and
/// WebP: the EXIF structure (maker notes and tags nobody here knows
/// included), the XMP packet (any namespace), the Photoshop resources that
/// hold IPTC, PNG text chunks and JPEG comments. The EXIF thumbnail — a
/// small copy of the original picture — is the one thing dropped.
///
/// Writing splices those blocks into a JPEG or PNG without re-encoding the
/// pixels, in place of the file's own metadata. What describes the file
/// rather than the photo stays the file's: its orientation and pixel size
/// are written into the copied EXIF (and the XMP orientation); its colour
/// profile and every other segment or chunk are kept as they were.
class ExifPhotoMetadataCodec implements IPhotoMetadataCodec {
  const ExifPhotoMetadataCodec();

  @override
  PhotoMetadata? read(Uint8List bytes) {
    final blocks = _orElse(null, () => _blocksOf(bytes));
    if (blocks == null) return null;
    final exif = switch (blocks.exif) {
      final tiff? => _withoutThumbnail(tiff),
      null => null,
    };
    final metadata = _summaryOf(exif).copyWith(
      exif: exif == null ? null : base64Encode(exif),
      xmp: blocks.xmp,
      iptc: blocks.iptc == null ? null : base64Encode(blocks.iptc!),
      texts: blocks.texts,
    );
    return metadata.isEmpty ? null : metadata;
  }

  @override
  Uint8List? write(
    Uint8List bytes,
    PhotoMetadata metadata, {
    AiEditMark? aiMark,
  }) => _orElse(
    null,
    () => switch (sniffImageMime(bytes)) {
      'image/jpeg' => _writeJpeg(bytes, metadata, aiMark),
      'image/png' => _writePng(bytes, metadata, aiMark),
      _ => null,
    },
  );
}

/// [parse], or [fallback] when the bytes are not what they claim to be.
T _orElse<T>(T fallback, T Function() parse) {
  try {
    return parse();
  } on RangeError {
    return fallback;
  } on FormatException {
    return fallback;
  }
}

/// A file's metadata blocks, verbatim.
class _Blocks {
  /// TIFF structure.
  final Uint8List? exif;
  final String? xmp;

  /// Photoshop image resources.
  final Uint8List? iptc;
  final List<PhotoText> texts;

  const _Blocks({this.exif, this.xmp, this.iptc, this.texts = const []});

  static const none = _Blocks();
}

_Blocks _blocksOf(Uint8List bytes) => switch (sniffImageMime(bytes)) {
  'image/jpeg' => _jpegBlocks(bytes),
  'image/png' => _pngBlocks(bytes),
  'image/webp' => _webpBlocks(bytes),
  _ => _Blocks.none,
};

/// What describes the destination file itself: EXIF orientation (when not
/// the default) and pixel size.
typedef _Own = ({int? orientation, (int, int)? size});

/// The IFD0 orientation of [exif], when it is not the default.
int? _orientationOf(Uint8List? exif) {
  if (exif == null) return null;
  final t = _Tiff(exif);
  final value = t.integer(t.ifd0[_Tag.orientation]);
  return value != null && value >= 2 && value <= 8 ? value : null;
}

/// The blocks to splice into a file with [own] properties.
_Blocks _blocksToWrite(PhotoMetadata m, _Own own, AiEditMark? mark) => _Blocks(
  exif: _exifFor(m, own),
  xmp: _xmpFor(m.xmp, own.orientation, mark),
  iptc: m.iptcBytes,
  texts: m.texts,
);

/// The EXIF to write: the photo's own block fitted to the file, or — for
/// images attached by an earlier version, which kept only the display
/// fields — one rebuilt from those. A file sideways on disk keeps saying
/// so even when there is nothing else to write.
Uint8List? _exifFor(PhotoMetadata m, _Own own) {
  if (m.exifBytes case final raw?) {
    final fitted = _fittedExif(
      raw,
      orientation: own.orientation ?? 1,
      size: own.size,
    );
    if (fitted != null) return fitted;
  }
  final hasDisplay =
      m.camera != null || m.captured != null || m.location != null;
  if (!hasDisplay && own.orientation == null) return null;
  return _writeTiff(m, orientation: own.orientation);
}

String? _xmpFor(String? xmp, int? orientation, AiEditMark? mark) {
  final packet = xmp == null ? null : _withOrientation(xmp, orientation ?? 1);
  return mark == null ? packet : _withAiMark(packet, mark);
}

// =====================================================================
// Containers
// =====================================================================

/// `Exif\0\0`: the header in front of the TIFF data in a JPEG APP1.
const _exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

/// In front of the XMP packet in a JPEG APP1.
final _xmpHeader = [...ascii.encode('http://ns.adobe.com/xap/1.0/'), 0];

/// In front of the Photoshop resources in a JPEG APP13.
final _photoshopHeader = [...ascii.encode('Photoshop 3.0'), 0];

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// PNG text keyword of an XMP packet.
const _pngXmpKeyword = 'XML:com.adobe.xmp';

/// PNG text keyword under which ImageMagick and exiftool keep Photoshop
/// resources.
const _pngPhotoshopKeyword = 'Raw profile type 8bim';

bool _startsWith(List<int> b, int offset, List<int> prefix) {
  if (offset + prefix.length > b.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (b[offset + i] != prefix[i]) return false;
  }
  return true;
}

/// Some writers put the JPEG header in front of the TIFF data even where
/// the container does not call for it (PNG `eXIf`, WebP `EXIF`).
Uint8List _withoutExifHeader(Uint8List b) => _startsWith(b, 0, _exifHeader)
    ? Uint8List.sublistView(b, _exifHeader.length)
    : b;

// --- JPEG ------------------------------------------------------------

/// Largest payload a JPEG marker segment can carry.
const _maxSegmentPayload = 0xFFFF - 2;

/// A marker segment before the scan data: from its `0xFF` at [start] to
/// [end] (exclusive); the payload starts at [payload].
typedef _Segment = ({int marker, int start, int payload, int end});

/// The marker segments before the first scan, and where the scan (and the
/// rest of the file, copied verbatim) starts.
({List<_Segment> segments, int scan}) _jpegSegments(Uint8List b) {
  final segments = <_Segment>[];
  var i = 2; // after SOI
  while (i + 1 < b.length) {
    if (b[i] != 0xFF) throw const FormatException('JPEG: marker expected');
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return (segments: segments, scan: i);
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      segments.add((marker: marker, start: i, payload: i + 2, end: i + 2));
      i += 2;
      continue;
    }
    if (i + 4 > b.length) throw const FormatException('JPEG: truncated');
    final length = (b[i + 2] << 8) | b[i + 3];
    final end = i + 2 + length;
    if (length < 2 || end > b.length) {
      throw const FormatException('JPEG: bad segment length');
    }
    segments.add((marker: marker, start: i, payload: i + 4, end: end));
    i = end;
  }
  throw const FormatException('JPEG: no image data');
}

/// The first EXIF block among [segments].
Uint8List? _jpegExif(Uint8List b, List<_Segment> segments) {
  for (final s in segments) {
    if (s.marker == 0xE1 && _startsWith(b, s.payload, _exifHeader)) {
      return _validTiff(
        Uint8List.sublistView(b, s.payload + _exifHeader.length, s.end),
      );
    }
  }
  return null;
}

_Blocks _jpegBlocks(Uint8List b) {
  final segments = _jpegSegments(b).segments;
  String? xmp;
  final photoshop = BytesBuilder(copy: false);
  final texts = <PhotoText>[];
  for (final s in segments) {
    final payload = Uint8List.sublistView(b, s.payload, s.end);
    switch (s.marker) {
      case 0xE1 when xmp == null && _startsWith(payload, 0, _xmpHeader):
        xmp = _compactXmp(
          utf8.decode(
            Uint8List.sublistView(payload, _xmpHeader.length),
            allowMalformed: true,
          ),
        );
      // Large resource blocks are split over consecutive APP13s.
      case 0xED when _startsWith(payload, 0, _photoshopHeader):
        photoshop.add(Uint8List.sublistView(payload, _photoshopHeader.length));
      case 0xFE:
        final text = utf8
            .decode(payload, allowMalformed: true)
            .replaceAll('\u0000', '')
            .trim();
        if (text.isNotEmpty) {
          texts.add(PhotoText(keyword: 'Comment', text: text));
        }
    }
  }
  return _Blocks(
    exif: _jpegExif(b, segments),
    xmp: xmp,
    iptc: _withoutThumbnailResources(photoshop.takeBytes()),
    texts: texts,
  );
}

/// `(width, height)` from the frame header.
(int, int)? _jpegSize(Uint8List b, List<_Segment> segments) {
  for (final s in segments) {
    final isFrame =
        s.marker >= 0xC0 &&
        s.marker <= 0xCF &&
        s.marker != 0xC4 &&
        s.marker != 0xC8 &&
        s.marker != 0xCC;
    if (isFrame && s.payload + 5 <= s.end) {
      final p = s.payload;
      return ((b[p + 3] << 8) | b[p + 4], (b[p + 1] << 8) | b[p + 2]);
    }
  }
  return null;
}

/// [b] with [m] as its metadata; one walk of the file serves the
/// orientation, the size and the splice.
Uint8List _writeJpeg(Uint8List b, PhotoMetadata m, AiEditMark? mark) {
  final (:segments, :scan) = _jpegSegments(b);
  final blocks = _blocksToWrite(m, (
    orientation: _orientationOf(_jpegExif(b, segments)),
    size: _jpegSize(b, segments),
  ), mark);
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var i = 0;
  // JFIF wants its APP0 right after SOI: leave it there, ours follow.
  for (; i < segments.length && segments[i].marker == 0xE0; i++) {
    out.add(Uint8List.sublistView(b, segments[i].start, segments[i].end));
  }
  void addSegment(int marker, List<List<int>> parts) {
    final length = parts.fold(0, (n, p) => n + p.length);
    // Blocks too large for one segment (EXIF or XMP that came from a PNG)
    // have no standard way to be split: they are left out.
    if (length > _maxSegmentPayload) return;
    out.add([0xFF, marker, (length + 2) >> 8, (length + 2) & 0xFF]);
    parts.forEach(out.add);
  }

  if (blocks.exif case final exif?) addSegment(0xE1, [_exifHeader, exif]);
  if (blocks.xmp case final xmp?) {
    addSegment(0xE1, [_xmpHeader, utf8.encode(xmp)]);
  }
  if (blocks.iptc case final resources?) {
    const room = _maxSegmentPayload - 14; // after "Photoshop 3.0\0"
    for (var at = 0; at < resources.length; at += room) {
      final end = math.min(at + room, resources.length);
      addSegment(0xED, [
        _photoshopHeader,
        Uint8List.sublistView(resources, at, end),
      ]);
    }
  }
  for (final t in blocks.texts) {
    final text = t.keyword == 'Comment' ? t.text : '${t.keyword}: ${t.text}';
    addSegment(0xFE, [utf8.encode(text)]);
  }
  for (; i < segments.length; i++) {
    final s = segments[i];
    // APP1 is EXIF or XMP, APP13 Photoshop/IPTC, COM a comment: the
    // metadata being replaced. Everything else describes this file.
    if (s.marker == 0xE1 || s.marker == 0xED || s.marker == 0xFE) continue;
    out.add(Uint8List.sublistView(b, s.start, s.end));
  }
  out.add(Uint8List.sublistView(b, scan));
  return out.takeBytes();
}

// --- PNG -------------------------------------------------------------

/// A chunk from its length field at [start] to the end of its CRC [end];
/// its data spans [data, dataEnd).
typedef _Chunk = ({String type, int start, int data, int dataEnd, int end});

List<_Chunk> _pngChunks(Uint8List b) {
  final view = ByteData.sublistView(b);
  final chunks = <_Chunk>[];
  var i = _pngSignature.length;
  while (i + 12 <= b.length) {
    final length = view.getUint32(i);
    final dataEnd = i + 8 + length;
    if (dataEnd + 4 > b.length) {
      throw const FormatException('PNG: truncated chunk');
    }
    final type = String.fromCharCodes(b, i + 4, i + 8);
    chunks.add((
      type: type,
      start: i,
      data: i + 8,
      dataEnd: dataEnd,
      end: dataEnd + 4,
    ));
    if (type == 'IEND') return chunks;
    i = dataEnd + 4;
  }
  throw const FormatException('PNG: no IEND');
}

const _pngTextChunks = {'tEXt', 'zTXt', 'iTXt'};

/// The EXIF block among [chunks].
Uint8List? _pngExif(Uint8List b, List<_Chunk> chunks) {
  for (final c in chunks) {
    if (c.type == 'eXIf') {
      return _validTiff(
        _withoutExifHeader(Uint8List.sublistView(b, c.data, c.dataEnd)),
      );
    }
  }
  return null;
}

_Blocks _pngBlocks(Uint8List b) {
  final chunks = _pngChunks(b);
  String? xmp;
  final texts = <PhotoText>[];
  for (final c in chunks) {
    if (!_pngTextChunks.contains(c.type)) continue;
    final text = _pngText(c.type, Uint8List.sublistView(b, c.data, c.dataEnd));
    if (text == null) continue;
    if (text.keyword == _pngXmpKeyword) {
      xmp ??= _compactXmp(text.text);
    } else {
      texts.add(text);
    }
  }
  return _Blocks(exif: _pngExif(b, chunks), xmp: xmp, texts: texts);
}

/// A `tEXt`, `zTXt` or `iTXt` chunk's keyword and text; `null` when it
/// does not parse.
PhotoText? _pngText(String type, Uint8List d) {
  final nul = d.indexOf(0);
  if (nul < 1) return null;
  final keyword = latin1.decode(Uint8List.sublistView(d, 0, nul));
  final text = _orElse<String?>(null, () {
    switch (type) {
      case 'tEXt':
        return latin1.decode(Uint8List.sublistView(d, nul + 1));
      case 'zTXt': // compression method, then deflate data
        return latin1.decode(zlib.decode(Uint8List.sublistView(d, nul + 2)));
      default: // iTXt: flag, method, language\0, translated keyword\0, text
        final compressed = d[nul + 1] == 1;
        final language = d.indexOf(0, nul + 3);
        if (language < 0) return null;
        final translated = d.indexOf(0, language + 1);
        if (translated < 0) return null;
        final body = Uint8List.sublistView(d, translated + 1);
        return utf8.decode(
          compressed ? zlib.decode(body) : body,
          allowMalformed: true,
        );
    }
  });
  return text == null ? null : PhotoText(keyword: keyword, text: text);
}

/// [b] with [m] as its metadata; one walk of the file serves the
/// orientation, the size and the splice.
Uint8List _writePng(Uint8List b, PhotoMetadata m, AiEditMark? mark) {
  final chunks = _pngChunks(b);
  final ihdr = chunks.first;
  if (ihdr.type != 'IHDR' || ihdr.dataEnd - ihdr.data < 8) {
    throw const FormatException('PNG: IHDR expected first');
  }
  final view = ByteData.sublistView(b);
  final blocks = _blocksToWrite(m, (
    orientation: _orientationOf(_pngExif(b, chunks)),
    size: (view.getUint32(ihdr.data), view.getUint32(ihdr.data + 4)),
  ), mark);
  final out = BytesBuilder(copy: false)
    ..add(_pngSignature)
    ..add(Uint8List.sublistView(b, ihdr.start, ihdr.end));
  // Right after IHDR, ahead of PLTE and IDAT, where every reader looks.
  if (blocks.exif case final exif?) out.add(_pngChunk('eXIf', [exif]));
  if (blocks.xmp case final xmp?) out.add(_pngITxt(_pngXmpKeyword, xmp));
  if (blocks.iptc case final resources?) {
    out.add(
      _pngChunk('tEXt', [
        latin1.encode(_pngPhotoshopKeyword),
        const [0],
        ascii.encode(_rawProfile('8bim', resources)),
      ]),
    );
  }
  for (final t in blocks.texts) {
    if (_isPngKeyword(t.keyword)) out.add(_pngITxt(t.keyword, t.text));
  }
  for (final c in chunks.skip(1)) {
    // EXIF and text are the metadata being replaced; everything else
    // (colour profile, gamma, density…) describes this file.
    if (c.type == 'eXIf' || _pngTextChunks.contains(c.type)) continue;
    out.add(Uint8List.sublistView(b, c.start, c.end));
  }
  return out.takeBytes();
}

/// 1–79 printable Latin-1 characters, as PNG requires of a keyword.
bool _isPngKeyword(String k) =>
    k.isNotEmpty &&
    k.length <= 79 &&
    k.codeUnits.every((c) => (c >= 32 && c <= 126) || (c >= 161 && c <= 255));

/// Uncompressed `iTXt`: keyword, then separator, no compression, no method,
/// no language, no translated keyword — five zero bytes — then UTF-8.
Uint8List _pngITxt(String keyword, String text) => _pngChunk('iTXt', [
  latin1.encode(keyword),
  const [0, 0, 0, 0, 0],
  utf8.encode(text),
]);

/// ImageMagick's text encoding of a binary profile: type, length, then
/// hex, 36 bytes a line.
String _rawProfile(String type, Uint8List data) {
  final hex = StringBuffer();
  for (var i = 0; i < data.length; i++) {
    if (i % 36 == 0) hex.write('\n');
    hex.write(data[i].toRadixString(16).padLeft(2, '0'));
  }
  return '\n$type\n${data.length.toString().padLeft(8)}$hex\n';
}

/// A chunk whose data is [parts] end to end.
Uint8List _pngChunk(String type, List<List<int>> parts) {
  final length = parts.fold(0, (n, p) => n + p.length);
  final out = Uint8List(12 + length);
  final view = ByteData.sublistView(out);
  view.setUint32(0, length);
  out.setRange(4, 8, ascii.encode(type));
  var at = 8;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  view.setUint32(8 + length, _crc32(out, 4, 8 + length));
  return out;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

/// CRC-32 of `bytes[start, end)`, as PNG chunks carry it.
int _crc32(Uint8List bytes, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

// --- WebP (read only) ------------------------------------------------

_Blocks _webpBlocks(Uint8List b) {
  final view = ByteData.sublistView(b);
  Uint8List? exif;
  String? xmp;
  var i = 12; // after RIFF <size> WEBP
  while (i + 8 <= b.length) {
    final size = view.getUint32(i + 4, Endian.little);
    final start = i + 8;
    if (start + size > b.length) break;
    final data = Uint8List.sublistView(b, start, start + size);
    if (_startsWith(b, i, ascii.encode('EXIF'))) {
      exif ??= _validTiff(_withoutExifHeader(data));
    } else if (_startsWith(b, i, ascii.encode('XMP '))) {
      xmp ??= _compactXmp(utf8.decode(data, allowMalformed: true));
    }
    i = start + size + (size & 1);
  }
  return _Blocks(exif: exif, xmp: xmp);
}

// --- Photoshop image resources ---------------------------------------

/// [resources] without the thumbnail resources (a small copy of the
/// original picture); as they are when they do not parse, `null` when
/// nothing is left.
Uint8List? _withoutThumbnailResources(Uint8List resources) {
  if (resources.isEmpty) return null;
  final view = ByteData.sublistView(resources);
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < resources.length) {
    // Signature (4), id (2), Pascal name padded to even, size (4), data
    // padded to even.
    if (i + 7 > resources.length) return resources;
    final id = view.getUint16(i + 4);
    final nameLength = resources[i + 6];
    var at = i + 7 + nameLength;
    if (at.isOdd) at++;
    if (at + 4 > resources.length) return resources;
    final size = view.getUint32(at);
    final end = math.min(at + 4 + size + (size & 1), resources.length);
    if (at + 4 + size > resources.length) return resources;
    if (id != 0x0409 && id != 0x040C) {
      out.add(Uint8List.sublistView(resources, i, end));
    }
    i = end;
  }
  final kept = out.takeBytes();
  return kept.isEmpty ? null : kept;
}

// =====================================================================
// TIFF (the body of an EXIF block)
// =====================================================================

abstract final class _Tag {
  // IFD0
  static const imageWidth = 0x0100;
  static const imageLength = 0x0101;
  static const make = 0x010F;
  static const model = 0x0110;
  static const orientation = 0x0112;
  static const exifIfd = 0x8769;
  static const gpsIfd = 0x8825;

  // IFD1
  static const thumbnailOffset = 0x0201;
  static const thumbnailLength = 0x0202;

  // Exif IFD
  static const exposureTime = 0x829A;
  static const fNumber = 0x829D;
  static const iso = 0x8827;
  static const exifVersion = 0x9000;
  static const dateTimeOriginal = 0x9003;
  static const dateTimeDigitized = 0x9004;
  static const offsetTimeOriginal = 0x9011;
  static const offsetTimeDigitized = 0x9012;
  static const focalLength = 0x920A;
  static const pixelXDimension = 0xA002;
  static const pixelYDimension = 0xA003;
  static const focalLength35mm = 0xA405;
  static const lensMake = 0xA433;
  static const lensModel = 0xA434;

  // GPS IFD
  static const gpsVersion = 0x0000;
  static const latitudeRef = 0x0001;
  static const latitude = 0x0002;
  static const longitudeRef = 0x0003;
  static const longitude = 0x0004;
  static const altitudeRef = 0x0005;
  static const altitude = 0x0006;
  static const directionRef = 0x0010;
  static const direction = 0x0011;
}

/// Byte size of one value of each TIFF field type (129 is Exif 3's UTF-8).
const _typeSizes = {
  1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, //
  12: 8, 129: 1,
};

/// An IFD entry: its type, value count, and where the values start.
typedef _Entry = ({int type, int count, int at});

/// Reads a TIFF structure, and patches values in place (same size, so
/// every offset stays valid).
class _Tiff {
  final Uint8List bytes;
  final ByteData data;
  final Endian endian;

  factory _Tiff(Uint8List bytes) {
    if (bytes.length < 8) throw const FormatException('TIFF: too short');
    final endian = switch ((bytes[0], bytes[1])) {
      (0x49, 0x49) => Endian.little,
      (0x4D, 0x4D) => Endian.big,
      _ => throw const FormatException('TIFF: bad byte order'),
    };
    final tiff = _Tiff._(bytes, endian);
    if (tiff.u16(2) != 42) throw const FormatException('TIFF: bad magic');
    return tiff;
  }

  _Tiff._(this.bytes, this.endian) : data = ByteData.sublistView(bytes);

  int u16(int at) => data.getUint16(at, endian);
  int u32(int at) => data.getUint32(at, endian);

  Map<int, _Entry> get ifd0 => ifd(u32(4));

  /// The IFD a pointer entry ([_Tag.exifIfd], [_Tag.gpsIfd]) points to.
  Map<int, _Entry> subIfd(_Entry? pointer) =>
      pointer == null ? const {} : ifd(integer(pointer) ?? 0);

  Map<int, _Entry> ifd(int offset) {
    if (offset < 8 || offset + 2 > bytes.length) return const {};
    final entries = <int, _Entry>{};
    final n = u16(offset);
    for (var k = 0; k < n; k++) {
      final e = offset + 2 + 12 * k;
      if (e + 12 > bytes.length) break;
      final type = u16(e + 2);
      final count = u32(e + 4);
      final unit = _typeSizes[type];
      if (unit == null || count == 0 || count > bytes.length) continue;
      final size = unit * count;
      final at = size <= 4 ? e + 8 : u32(e + 8);
      if (at + size > bytes.length) continue;
      entries[u16(e)] = (type: type, count: count, at: at);
    }
    return entries;
  }

  /// An ASCII / UTF-8 value, cut at its terminator and trimmed; `null`
  /// when absent or blank.
  String? text(_Entry? e) {
    if (e == null || (e.type != 2 && e.type != 129)) return null;
    var end = e.at;
    while (end < e.at + e.count && bytes[end] != 0) {
      end++;
    }
    final s = utf8
        .decode(Uint8List.sublistView(bytes, e.at, end), allowMalformed: true)
        .trim();
    return s.isEmpty ? null : s;
  }

  int? integer(_Entry? e, [int index = 0]) {
    if (e == null || index >= e.count) return null;
    return switch (e.type) {
      1 || 7 => bytes[e.at + index],
      3 => u16(e.at + 2 * index),
      4 => u32(e.at + 4 * index),
      8 => data.getInt16(e.at + 2 * index, endian),
      9 => data.getInt32(e.at + 4 * index, endian),
      _ => null,
    };
  }

  double? number(_Entry? e, [int index = 0]) {
    if (e == null || index >= e.count) return null;
    switch (e.type) {
      case 5:
        final den = u32(e.at + 8 * index + 4);
        return den == 0 ? null : u32(e.at + 8 * index) / den;
      case 10:
        final den = data.getInt32(e.at + 8 * index + 4, endian);
        return den == 0 ? null : data.getInt32(e.at + 8 * index, endian) / den;
      case 11:
        return data.getFloat32(e.at + 4 * index, endian);
      case 12:
        return data.getFloat64(e.at + 8 * index, endian);
      default:
        return integer(e, index)?.toDouble();
    }
  }

  double? positive(_Entry? e) => switch (number(e)) {
    final v? when v > 0 && v.isFinite => v,
    _ => null,
  };

  int? positiveInt(_Entry? e) => switch (integer(e)) {
    final v? when v > 0 => v,
    _ => null,
  };

  /// Overwrites a SHORT or LONG value, when [e] exists and [value] fits.
  void setInteger(_Entry? e, int value) {
    if (e == null) return;
    if (e.type == 3 && value <= 0xFFFF) data.setUint16(e.at, value, endian);
    if (e.type == 4) data.setUint32(e.at, value, endian);
  }
}

/// [bytes] when they look like a TIFF structure, else `null`.
Uint8List? _validTiff(Uint8List bytes) => _orElse(null, () {
  final ifd0 = _Tiff(bytes).u32(4);
  return ifd0 >= 8 && ifd0 + 2 <= bytes.length ? bytes : null;
});

/// A copy of [tiff] without its thumbnail: the IFD1 link is cut and the
/// picture zeroed — cut off when, as usual, it ends the block.
Uint8List _withoutThumbnail(Uint8List tiff) {
  final out = Uint8List.fromList(tiff);
  return _orElse(out, () {
    final t = _Tiff(out);
    final ifd0 = t.u32(4);
    final link = ifd0 + 2 + 12 * t.u16(ifd0);
    if (link + 4 > out.length) return out;
    final ifd1 = t.u32(link);
    if (ifd1 == 0) return out;
    t.data.setUint32(link, 0, t.endian);
    final entries = t.ifd(ifd1);
    final start = t.integer(entries[_Tag.thumbnailOffset]);
    final length = t.integer(entries[_Tag.thumbnailLength]);
    if (start == null ||
        length == null ||
        start < 8 ||
        start + length > out.length) {
      return out;
    }
    out.fillRange(start, start + length, 0);
    return out.length - (start + length) <= 3 ? out.sublist(0, start) : out;
  });
}

/// A copy of the photo's [raw] EXIF describing the destination file: its
/// [orientation] and pixel [size]. `null` when [raw] does not parse.
Uint8List? _fittedExif(
  Uint8List raw, {
  required int orientation,
  required (int, int)? size,
}) => _orElse(null, () {
  final out = Uint8List.fromList(raw);
  final t = _Tiff(out);
  final ifd0 = t.ifd0;
  t.setInteger(ifd0[_Tag.orientation], orientation);
  if (size case (final width, final height)) {
    final exif = t.subIfd(ifd0[_Tag.exifIfd]);
    t
      ..setInteger(ifd0[_Tag.imageWidth], width)
      ..setInteger(ifd0[_Tag.imageLength], height)
      ..setInteger(exif[_Tag.pixelXDimension], width)
      ..setInteger(exif[_Tag.pixelYDimension], height);
  }
  return out;
});

// --- Reading what to show --------------------------------------------

final _utcOffset = RegExp(r'^[+-]\d{2}:\d{2}$');

/// Camera, date and place from [exif], for display.
PhotoMetadata _summaryOf(Uint8List? exif) {
  if (exif == null) return const PhotoMetadata();
  return _orElse(const PhotoMetadata(), () {
    final t = _Tiff(exif);
    final ifd0 = t.ifd0;
    final exifIfd = t.subIfd(ifd0[_Tag.exifIfd]);
    return PhotoMetadata(
      camera: _readCamera(t, ifd0, exifIfd),
      captured: _readCaptureTime(t, exifIfd),
      location: _readLocation(t, t.subIfd(ifd0[_Tag.gpsIfd])),
    );
  });
}

CameraInfo? _readCamera(_Tiff t, Map<int, _Entry> ifd0, Map<int, _Entry> exif) {
  final camera = CameraInfo(
    make: t.text(ifd0[_Tag.make]),
    model: t.text(ifd0[_Tag.model]),
    lensMake: t.text(exif[_Tag.lensMake]),
    lensModel: t.text(exif[_Tag.lensModel]),
    focalLength: t.positive(exif[_Tag.focalLength]),
    focalLength35mm: t.positiveInt(exif[_Tag.focalLength35mm]),
    fNumber: t.positive(exif[_Tag.fNumber]),
    exposureTime: t.positive(exif[_Tag.exposureTime]),
    iso: t.positiveInt(exif[_Tag.iso]),
  );
  return camera == const CameraInfo() ? null : camera;
}

CaptureTime? _readCaptureTime(_Tiff t, Map<int, _Entry> exif) {
  const pairs = [
    (_Tag.dateTimeOriginal, _Tag.offsetTimeOriginal),
    (_Tag.dateTimeDigitized, _Tag.offsetTimeDigitized),
  ];
  for (final (dateTag, offsetTag) in pairs) {
    final local = t.text(exif[dateTag]);
    // Cameras without a clock write zeros.
    if (local == null ||
        local.startsWith('0000') ||
        CaptureTime(local: local).localDateTime == null) {
      continue;
    }
    final offset = t.text(exif[offsetTag]);
    return CaptureTime(
      local: local,
      offset: offset != null && _utcOffset.hasMatch(offset) ? offset : null,
    );
  }
  return null;
}

GeoLocation? _readLocation(_Tiff t, Map<int, _Entry> gps) {
  final lat = _readDegrees(t, gps[_Tag.latitude]);
  final lon = _readDegrees(t, gps[_Tag.longitude]);
  if (lat == null || lon == null) return null;
  final latitude = t.text(gps[_Tag.latitudeRef]) == 'S' ? -lat : lat;
  final longitude = t.text(gps[_Tag.longitudeRef]) == 'W' ? -lon : lon;
  if (latitude.abs() > 90 || longitude.abs() > 180) return null;
  // What a receiver without a fix writes.
  if (latitude == 0 && longitude == 0) return null;
  final altitude = t.number(gps[_Tag.altitude]);
  final direction = t.number(gps[_Tag.direction]);
  return GeoLocation(
    latitude: latitude,
    longitude: longitude,
    altitude: altitude == null || !altitude.isFinite
        ? null
        : t.integer(gps[_Tag.altitudeRef]) == 1
        ? -altitude
        : altitude,
    direction: direction != null && direction >= 0 && direction <= 360
        ? direction
        : null,
    magneticNorth: t.text(gps[_Tag.directionRef]) == 'M',
  );
}

/// Degrees, minutes, seconds — or decimal degrees in the first value, as
/// some writers do. Rounded to 1e-8° (about a millimetre) so a value read
/// back after writing is the value written, not its float residue.
double? _readDegrees(_Tiff t, _Entry? e) {
  final degrees = t.number(e);
  if (degrees == null || !degrees.isFinite) return null;
  final minutes = t.number(e, 1) ?? 0;
  final seconds = t.number(e, 2) ?? 0;
  final value = degrees + minutes / 60 + seconds / 3600;
  return (value * 1e8).round() / 1e8;
}

// --- Rebuilding from the display fields ------------------------------

/// One IFD entry with its value already encoded (big-endian).
class _Field {
  final int tag;
  final int type;
  final int count;
  final Uint8List value;

  const _Field(this.tag, this.type, this.count, this.value);

  factory _Field.ascii(int tag, String s) {
    final bytes = Uint8List.fromList([...utf8.encode(s), 0]);
    return _Field(tag, 2, bytes.length, bytes);
  }

  factory _Field.bytes(int tag, List<int> values, {int type = 1}) =>
      _Field(tag, type, values.length, Uint8List.fromList(values));

  factory _Field.short(int tag, int value) => _Field(
    tag,
    3,
    1,
    (ByteData(2)..setUint16(0, value)).buffer.asUint8List(),
  );

  factory _Field.long(int tag, int value) => _Field(
    tag,
    4,
    1,
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List(),
  );

  factory _Field.rationals(int tag, List<(int, int)> values) {
    final data = ByteData(8 * values.length);
    for (final (i, (numerator, denominator)) in values.indexed) {
      data
        ..setUint32(8 * i, numerator)
        ..setUint32(8 * i + 4, denominator);
    }
    return _Field(tag, 5, values.length, data.buffer.asUint8List());
  }

  factory _Field.rational(int tag, (int, int) value) =>
      _Field.rationals(tag, [value]);
}

/// TIFF header (big-endian, IFD0 right after it).
const _tiffHeader = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08];

/// An EXIF block holding [m]'s display fields, for images attached before
/// the photo's own blocks were kept.
Uint8List _writeTiff(PhotoMetadata m, {required int? orientation}) {
  final camera = m.camera;
  final captured = m.captured;
  final location = m.location;

  final exif = [
    _Field.bytes(_Tag.exifVersion, ascii.encode('0232'), type: 7),
    if (camera != null) ...[
      if (camera.exposureTime case final v?)
        _Field.rational(_Tag.exposureTime, _exposureRational(v)),
      if (camera.fNumber case final v?)
        _Field.rational(_Tag.fNumber, _fixed(v, 100)),
      if (camera.iso case final v?) _Field.short(_Tag.iso, _u16(v)),
      if (camera.focalLength case final v?)
        _Field.rational(_Tag.focalLength, _fixed(v, 100)),
      if (camera.focalLength35mm case final v?)
        _Field.short(_Tag.focalLength35mm, _u16(v)),
      if (camera.lensMake case final v?) _Field.ascii(_Tag.lensMake, v),
      if (camera.lensModel case final v?) _Field.ascii(_Tag.lensModel, v),
    ],
    if (captured != null) ...[
      _Field.ascii(_Tag.dateTimeOriginal, captured.local),
      _Field.ascii(_Tag.dateTimeDigitized, captured.local),
      if (captured.offset case final o?) ...[
        _Field.ascii(_Tag.offsetTimeOriginal, o),
        _Field.ascii(_Tag.offsetTimeDigitized, o),
      ],
    ],
  ];

  final gps = [
    if (location != null) ...[
      _Field.bytes(_Tag.gpsVersion, const [2, 2, 0, 0]),
      _Field.ascii(_Tag.latitudeRef, location.latitude < 0 ? 'S' : 'N'),
      _Field.rationals(_Tag.latitude, _dms(location.latitude)),
      _Field.ascii(_Tag.longitudeRef, location.longitude < 0 ? 'W' : 'E'),
      _Field.rationals(_Tag.longitude, _dms(location.longitude)),
      if (location.altitude case final a?) ...[
        _Field.bytes(_Tag.altitudeRef, [if (a < 0) 1 else 0]),
        _Field.rational(_Tag.altitude, _fixed(a.abs(), 100)),
      ],
      if (location.direction case final d?) ...[
        _Field.ascii(_Tag.directionRef, location.magneticNorth ? 'M' : 'T'),
        _Field.rational(_Tag.direction, _fixed(d, 100)),
      ],
    ],
  ];

  List<_Field> ifd0({int exifAt = 0, int gpsAt = 0}) => [
    if (camera?.make case final v?) _Field.ascii(_Tag.make, v),
    if (camera?.model case final v?) _Field.ascii(_Tag.model, v),
    if (orientation != null) _Field.short(_Tag.orientation, orientation),
    _Field.long(_Tag.exifIfd, exifAt),
    if (gps.isNotEmpty) _Field.long(_Tag.gpsIfd, gpsAt),
  ];

  // Header, IFD0, Exif IFD, GPS IFD; each IFD followed by the values too
  // long to sit in its entries. Pointers are 4-byte values, so the sizes
  // do not depend on them.
  final exifAt = _tiffHeader.length + _ifdSize(ifd0());
  final gpsAt = exifAt + _ifdSize(exif);
  final out = BytesBuilder(copy: false)
    ..add(_tiffHeader)
    ..add(_ifdBytes(ifd0(exifAt: exifAt, gpsAt: gpsAt), _tiffHeader.length))
    ..add(_ifdBytes(exif, exifAt));
  if (gps.isNotEmpty) out.add(_ifdBytes(gps, gpsAt));
  return out.takeBytes();
}

int _ifdSize(List<_Field> fields) =>
    2 +
    12 * fields.length +
    4 +
    fields.fold<int>(
      0,
      (n, f) =>
          f.value.length > 4 ? n + f.value.length + (f.value.length & 1) : n,
    );

/// [fields] as an IFD placed at [start] (from the TIFF header), entries
/// sorted by tag as TIFF requires, no next IFD.
Uint8List _ifdBytes(List<_Field> fields, int start) {
  final sorted = [...fields]..sort((a, b) => a.tag.compareTo(b.tag));
  final out = Uint8List(_ifdSize(sorted));
  final view = ByteData.sublistView(out);
  view.setUint16(0, sorted.length);
  var next = 2 + 12 * sorted.length + 4;
  for (final (i, f) in sorted.indexed) {
    final entry = 2 + 12 * i;
    view
      ..setUint16(entry, f.tag)
      ..setUint16(entry + 2, f.type)
      ..setUint32(entry + 4, f.count);
    if (f.value.length <= 4) {
      out.setRange(entry + 8, entry + 8 + f.value.length, f.value);
    } else {
      view.setUint32(entry + 8, start + next);
      out.setRange(next, next + f.value.length, f.value);
      next += f.value.length + (f.value.length & 1);
    }
  }
  return out;
}

int _u16(int v) => v.clamp(1, 0xFFFF);

/// [v] (non-negative) as a fraction over [denominator].
(int, int) _fixed(double v, int denominator) =>
    ((math.max(v, 0) * denominator).round(), denominator);

/// Exposure times are fractions of a second: keep `1/N` as such.
(int, int) _exposureRational(double seconds) {
  if (seconds > 0 && seconds < 1) {
    final n = 1 / seconds;
    if ((n - n.round()).abs() < 1e-3) return (1, n.round());
  }
  return _fixed(seconds, 10000);
}

/// Decimal degrees as the degrees / minutes / seconds rationals of GPS
/// tags, seconds to 1/10000 (a few millimetres).
List<(int, int)> _dms(double degrees) {
  const perSecond = 10000;
  final units = (degrees.abs() * 3600 * perSecond).round();
  return [
    (units ~/ (3600 * perSecond), 1),
    ((units ~/ (60 * perSecond)) % 60, 1),
    (units % (60 * perSecond), perSecond),
  ];
}

// =====================================================================
// XMP
// =====================================================================

const _iptcExtNamespace = 'http://iptc.org/std/Iptc4xmpExt/2008-02-29/';

/// [packet] without the stray NULs and the whitespace padding writers
/// reserve for in-place edits (often most of its size).
String? _compactXmp(String packet) {
  final compact = packet
      .replaceAll('\u0000', '')
      .replaceFirst(RegExp(r'\s+(?=<\?xpacket end)'), '\n')
      .trim();
  return compact.isEmpty ? null : compact;
}

/// [packet] with its TIFF orientation, if it states one, set to the
/// file's.
String _withOrientation(String packet, int orientation) => packet
    .replaceAllMapped(
      RegExp(r'''(tiff:Orientation\s*=\s*["'])\d(["'])'''),
      (m) => '${m[1]}$orientation${m[2]}',
    )
    .replaceAllMapped(
      RegExp(r'(<tiff:Orientation>)\s*\d\s*(</tiff:Orientation>)'),
      (m) => '${m[1]}$orientation${m[2]}',
    );

/// [packet] declaring [mark] (IPTC digital source type): an existing
/// declaration — Apple Photos writes one after Clean Up — is updated,
/// otherwise one is added. A packet of our own when there was none.
String _withAiMark(String? packet, AiEditMark mark) {
  final source =
      'http://cv.iptc.org/newscodes/digitalsourcetype/'
      '${switch (mark) {
        AiEditMark.editedPhoto => 'compositeWithTrainedAlgorithmicMedia',
        AiEditMark.generated => 'trainedAlgorithmicMedia',
      }}';
  if (packet == null) return _ownXmpPacket(source);
  for (final form in [
    RegExp(r'''(Iptc4xmpExt:DigitalSourceType\s*=\s*["'])[^"']*(["'])'''),
    RegExp(
      '(<Iptc4xmpExt:DigitalSourceType>)[^<]*(</Iptc4xmpExt:DigitalSourceType>)',
    ),
    RegExp(
      r'''(<Iptc4xmpExt:DigitalSourceType\s+rdf:resource\s*=\s*["'])[^"']*(["'])''',
    ),
  ]) {
    if (form.hasMatch(packet)) {
      return packet.replaceFirstMapped(form, (m) => '${m[1]}$source${m[2]}');
    }
  }
  final end = packet.lastIndexOf('</rdf:RDF>');
  if (end < 0) return packet;
  return '${packet.substring(0, end)}'
      '<rdf:Description rdf:about="" xmlns:Iptc4xmpExt="$_iptcExtNamespace" '
      'Iptc4xmpExt:DigitalSourceType="$source"/>\n'
      '${packet.substring(end)}';
}

String _ownXmpPacket(String digitalSourceType) =>
    '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
    ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
    '  <rdf:Description rdf:about=""\n'
    '    xmlns:Iptc4xmpExt="$_iptcExtNamespace"\n'
    '    xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n'
    '    Iptc4xmpExt:DigitalSourceType="$digitalSourceType"\n'
    '    xmp:CreatorTool="${AppInfo.name}"/>\n'
    ' </rdf:RDF>\n'
    '</x:xmpmeta>\n'
    '<?xpacket end="w"?>';
