import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/core/image_mime.dart';

void main() {
  test('sniffImageMime recognises the supported formats only', () {
    expect(
      sniffImageMime(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])),
      'image/png',
    );
    expect(
      sniffImageMime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
      'image/jpeg',
    );
    expect(sniffImageMime(Uint8List.fromList('GIF89a'.codeUnits)), 'image/gif');
    expect(
      sniffImageMime(
        Uint8List.fromList([
          ...'RIFF'.codeUnits,
          0,
          0,
          0,
          0,
          ...'WEBP'.codeUnits,
        ]),
      ),
      'image/webp',
    );
    expect(sniffImageMime(Uint8List.fromList('%PDF-1.4'.codeUnits)), isNull);
    expect(sniffImageMime(Uint8List(0)), isNull);
  });

  test('every accepted MIME type has an extension for dialog filters', () {
    for (final mime in kImageMimeTypes) {
      final ext = mime.split('/').last;
      expect(kImageExtensions, contains(ext == 'jpeg' ? 'jpg' : ext));
    }
  });
}
