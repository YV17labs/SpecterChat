import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/image_export.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/presentation/ui/widgets/photo_metadata_text.dart';

import '../../../support/fakes.dart';

void main() {
  test('tooltip lines: camera, exposure, date, place', () {
    expect(photoMetadataLines(kPhotoSummary, locale: 'en-US'), [
      'iPhone 17',
      '5.96 mm · f/1.6 · 1/4329 s · ISO 40',
      'Jul 5, 2026, 7:41\u202fPM (UTC+02:00)',
      '42.56858° N, 8.75145° E',
    ]);
    expect(
      photoMetadataLines(
        locale: 'en-US',
        const PhotoSummary(
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
      photoMetadataSummary(kPhotoSummary, locale: 'en-US'),
      'iPhone 17 · Jul 5, 2026 · location',
    );
  });

  test("dates in the system's language, the rest in English", () {
    String date(String locale) =>
        photoMetadataLines(kPhotoSummary, locale: locale)[2];
    expect(date('fr-FR'), '5 juil. 2026, 19:41 (UTC+02:00)');
    expect(date('en-GB'), '5 Jul 2026, 19:41 (UTC+02:00)');
    expect(date('de-DE'), '5. Juli 2026, 19:41 (UTC+02:00)');
    // A region without formats of its own: its language's.
    expect(date('fr-BE'), startsWith('5 juil. 2026'));
    // A language intl does not know: English.
    expect(date('xx-YY'), 'Jul 5, 2026, 7:41\u202fPM (UTC+02:00)');
    expect(
      photoMetadataSummary(kPhotoSummary, locale: 'fr-FR'),
      'iPhone 17 · 5 juil. 2026 · location',
    );
  });

  test('without camera, date or place, a generic line', () {
    // A PNG with only text chunks, say.
    const nothingShown = PhotoSummary();
    expect(photoMetadataLines(nothingShown, locale: 'fr-FR'), [
      'Original photo metadata',
    ]);
    expect(
      photoMetadataSummary(nothingShown, locale: 'fr-FR'),
      'photo metadata',
    );
  });

  test('the save confirmation says what went in', () {
    String? message({required bool kept, required bool marked}) =>
        savedMetadataMessage(
          ImageExport(Uint8List(0), keptOriginal: kept, markedAiEdited: marked),
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
