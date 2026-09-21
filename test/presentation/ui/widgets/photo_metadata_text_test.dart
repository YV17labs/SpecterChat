import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/image_export.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/presentation/ui/widgets/photo_metadata_text.dart';

import '../../../support/fakes.dart';

void main() {
  test('tooltip lines: camera, exposure, date, place', () {
    expect(photoMetadataLines(kPhotoMetadata), [
      'iPhone 17',
      '5.96 mm · f/1.6 · 1/4329 s · ISO 40',
      '5 Jul 2026, 19:41 (UTC+02:00)',
      '42.56858° N, 8.75145° E',
    ]);
    expect(
      photoMetadataLines(
        const PhotoMetadata(
          camera: CameraInfo(make: 'Canon', exposureTime: 2.5),
          location: GeoLocation(
            latitude: -33.8568,
            longitude: -151.2153,
            altitude: -4.6,
          ),
        ),
      ),
      ['Canon', '2.5 s', '33.85680° S, 151.21530° W · -5 m'],
    );
  });

  test('thumbnail summary', () {
    expect(
      photoMetadataSummary(kPhotoMetadata),
      'iPhone 17 · 5 Jul 2026 · location',
    );
  });

  test('without camera, date or place, a generic line', () {
    const xmpOnly = PhotoMetadata(xmp: '<x:xmpmeta/>');
    expect(photoMetadataLines(xmpOnly), ['Original photo metadata']);
    expect(photoMetadataSummary(xmpOnly), 'photo metadata');
  });

  test('the save confirmation says what went in', () {
    final image = (bytes: Uint8List(0), mimeType: 'image/png');
    String? message({required bool kept, required bool marked}) =>
        savedMetadataMessage(
          ImageExport(image, keptOriginal: kept, markedAiEdited: marked),
        );

    expect(
      message(kept: true, marked: false),
      "Saved with the original photo's metadata",
    );
    expect(
      message(kept: true, marked: true),
      "Saved with the original photo's metadata, marked as AI-generated",
    );
    expect(message(kept: false, marked: true), 'Saved, marked as AI-generated');
    expect(message(kept: false, marked: false), isNull);
  });
}
