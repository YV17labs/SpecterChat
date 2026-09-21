import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';

void main() {
  test('the date taken round-trips as wall-clock time', () {
    final taken = CaptureTime(
      local: DateTime(2026, 7, 5, 19, 41, 50),
      offset: '+02:00',
    );
    final json = jsonDecode(jsonEncode(taken)) as Map<String, dynamic>;
    expect(json['local'], '2026-07-05T19:41:50.000');
    expect(CaptureTime.fromJson(json), taken);
  });

  group('PhotoMetadataRef', () {
    final summary = PhotoSummary(
      camera: const CameraInfo(make: 'Apple', model: 'iPhone 17'),
      captured: CaptureTime(
        local: DateTime(2026, 7, 5, 19, 41, 50),
        offset: '+02:00',
      ),
      location: const GeoLocation(latitude: 42.56858, longitude: 8.75145),
    );
    PhotoMetadataRef read(Object? json) => PhotoMetadataRef.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );

    test('what is shown, and where the blocks are', () {
      final stored = PhotoMetadataRef(summary: summary, blocksId: 'meta');
      final json = jsonDecode(jsonEncode(stored)) as Map<String, dynamic>;
      expect(json.keys, ['summary', 'blocksId']);
      expect(read(json), stored);
    });

    test('the first build: display fields only, at the top level', () {
      // EXIF-shaped date; lens, 35 mm focal length and GPS direction, no
      // longer shown, are ignored.
      final first = read({
        'camera': {
          'make': 'Apple',
          'model': 'iPhone 17',
          'lensMake': 'Apple',
          'focalLength35mm': 26,
        },
        'captured': {'local': '2026:07:05 19:41:50', 'offset': '+02:00'},
        'location': {
          'latitude': 42.56858,
          'longitude': 8.75145,
          'direction': 64.82,
          'magneticNorth': false,
        },
      });
      expect(first, PhotoMetadataRef(summary: summary));
    });

    test('the blocks an earlier build kept inline are read, not written', () {
      final inline = read({
        'camera': {'make': 'Apple', 'model': 'iPhone 17'},
        'exif': 'TU0AKg==',
        'xmp': '<x:xmpmeta/>',
        'iptc': null,
        'texts': [
          {'keyword': 'Comment', 'text': 'Calvi'},
        ],
      });
      expect(inline.summary.camera?.model, 'iPhone 17');
      expect(
        inline.inlineBlocks,
        const PhotoMetadataBlocks(
          exif: 'TU0AKg==',
          xmp: '<x:xmpmeta/>',
          texts: [PhotoText(keyword: 'Comment', text: 'Calvi')],
        ),
      );
      expect(inline.blocksId, isNull);
      expect(jsonEncode(inline), isNot(contains('exif')));

      // Empty texts, as that build always wrote them, are not blocks.
      expect(read({'texts': <Object>[]}).inlineBlocks, isNull);
    });
  });

  test('the blocks as their attachment, and back', () {
    const blocks = PhotoMetadataBlocks(
      exif: 'TU0AKg==',
      xmp: '<x:xmpmeta/>',
      texts: [PhotoText(keyword: 'parameters', text: '{"steps": 40}')],
    );
    expect(PhotoMetadataBlocks.decode(blocks.encode()), blocks);
    expect(PhotoMetadataBlocks.decode(Uint8List.fromList([0x89, 1])), isNull);
    expect(PhotoMetadataBlocks.decode(utf8.encode('[1]')), isNull);
  });
}
