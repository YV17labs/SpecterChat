import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/infrastructure/images/ui_image_normalizer.dart';

import '../../support/image_fixtures.dart';

void main() {
  testWidgets('keeps small images untouched and downscales large ones', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final small = await pngFixture(16, 8);
      final kept = await const UiImageNormalizer().normalize(small);
      expect(kept, isNotNull);
      expect(identical(kept!.bytes, small), isTrue);
      expect(kept.mimeType, 'image/png');

      final large = await pngFixture(300, 100);
      final shrunk = await const UiImageNormalizer(
        maxSide: 150,
      ).normalize(large);
      expect(shrunk, isNotNull);
      final descriptor = await ui.ImageDescriptor.encoded(
        await ui.ImmutableBuffer.fromUint8List(shrunk!.bytes),
      );
      expect(descriptor.width, 150);
      expect(descriptor.height, 50);
      descriptor.dispose();
    });
  });

  testWidgets('rejects bytes that are not an image', (tester) async {
    await tester.runAsync(() async {
      expect(
        await const UiImageNormalizer().normalize(
          Uint8List.fromList([1, 2, 3]),
        ),
        isNull,
      );
      // Sniffs as PNG but cannot be decoded.
      expect(
        await const UiImageNormalizer().normalize(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]),
        ),
        isNull,
      );
    });
  });
}
