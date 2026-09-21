import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/image_export.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/domain/services/i_photo_metadata_codec.dart';

/// Records what it was asked to write; returns [result].
class _RecordingCodec implements IPhotoMetadataCodec {
  final writes = <({PhotoMetadata metadata, AiEditMark? mark})>[];
  Uint8List? result = Uint8List.fromList([7, 7, 7]);

  @override
  PhotoMetadata? read(Uint8List bytes) => null;

  @override
  Uint8List? write(
    Uint8List bytes,
    PhotoMetadata metadata, {
    AiEditMark? aiMark,
  }) {
    writes.add((metadata: metadata, mark: aiMark));
    return result;
  }
}

void main() {
  const photo = PhotoMetadata(
    camera: CameraInfo(model: 'iPhone 17'),
    captured: CaptureTime(local: '2026:07:05 19:41:50'),
    location: GeoLocation(latitude: 42.56858, longitude: 8.75145),
  );
  final image = (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png');

  late _RecordingCodec codec;
  late ImageExporter exporter;
  setUp(() {
    codec = _RecordingCodec();
    exporter = ImageExporter(codec);
  });

  test("keeps all of the original's metadata, into a copy", () {
    final export = exporter.prepare(
      image,
      metadata: photo,
      generated: true,
      choices: const PhotoMetadataExport(markGeneratedAsAi: false),
    );

    expect(codec.writes.single, (metadata: photo, mark: null));
    expect(export.keptOriginal, isTrue);
    expect(export.markedAiEdited, isFalse);
    expect(export.image.bytes, [7, 7, 7]);
    expect(export.image.mimeType, 'image/png');
    expect(image.bytes, [1, 2, 3]);
  });

  test('switched off, the file is saved without it', () {
    final export = exporter.prepare(
      image,
      metadata: photo,
      generated: true,
      choices: const PhotoMetadataExport(
        keepOriginal: false,
        markGeneratedAsAi: false,
      ),
    );
    expect(codec.writes.single, (metadata: const PhotoMetadata(), mark: null));
    expect(export.keptOriginal, isFalse);
  });

  test('an image nothing is known about goes out untouched', () {
    final export = exporter.prepare(
      image,
      metadata: null,
      generated: false,
      choices: const PhotoMetadataExport(),
    );
    expect(codec.writes, isEmpty);
    expect(export.image.bytes, same(image.bytes));
    expect(export.keptOriginal, isFalse);
  });

  test('the AI mark: generated images only, when asked, by origin', () {
    const opted = PhotoMetadataExport();
    AiEditMark? markFor({
      required PhotoMetadata? metadata,
      required bool generated,
      PhotoMetadataExport choices = opted,
    }) {
      codec.writes.clear();
      exporter.prepare(
        image,
        metadata: metadata,
        generated: generated,
        choices: choices,
      );
      return codec.writes.singleOrNull?.mark;
    }

    expect(markFor(metadata: photo, generated: true), AiEditMark.editedPhoto);
    expect(markFor(metadata: null, generated: true), AiEditMark.generated);
    expect(markFor(metadata: photo, generated: false), isNull);
    expect(
      markFor(
        metadata: photo,
        generated: true,
        choices: const PhotoMetadataExport(markGeneratedAsAi: false),
      ),
      isNull,
    );
  });

  test('a file the codec cannot write into is saved as it is', () {
    codec.result = null;
    final export = exporter.prepare(
      image,
      metadata: photo,
      generated: true,
      choices: const PhotoMetadataExport(),
    );
    expect(export.image.bytes, same(image.bytes));
    expect(export.keptOriginal, isFalse);
    expect(export.markedAiEdited, isFalse);
  });
}
