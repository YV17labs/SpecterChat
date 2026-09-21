import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/image_export.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/domain/services/i_photo_metadata_codec.dart';

import '../../support/fakes.dart';

/// Records what it was asked to write; returns [result].
class _RecordingCodec implements IPhotoMetadataCodec {
  final writes = <({PhotoMetadataBlocks blocks, AiOrigin? mark})>[];
  Uint8List? result = Uint8List.fromList([7, 7, 7]);

  @override
  PhotoMetadata? read(Uint8List bytes) => null;

  @override
  Uint8List? write(
    Uint8List bytes,
    PhotoMetadataBlocks blocks, {
    AiOrigin? aiMark,
  }) {
    writes.add((blocks: blocks, mark: aiMark));
    return result;
  }
}

void main() {
  const shown = PhotoSummary(camera: CameraInfo(model: 'iPhone 17'));
  const blocks = kPhotoBlocks;
  const photo = PhotoMetadataRef(summary: shown, blocksId: 'meta');
  final bytes = Uint8List.fromList([1, 2, 3]);
  ImageContentBlock block({PhotoMetadataRef? metadata, AiOrigin? origin}) =>
      ImageContentBlock(
        attachmentId: 'att',
        mimeType: 'image/png',
        byteSize: bytes.length,
        photoMetadata: metadata,
        aiOrigin: origin,
      );

  late _RecordingCodec codec;
  late InMemoryAttachmentRepository attachments;
  late FakeImageIo io;
  late ImageExporter exporter;
  setUp(() async {
    codec = _RecordingCodec();
    attachments = InMemoryAttachmentRepository();
    io = FakeImageIo();
    await storePhotoMetadata(attachments, 'meta');
    exporter = ImageExporter(codec, attachments, io);
  });

  test('asks where first: a cancelled dialog prepares nothing', () async {
    final image = block(metadata: photo, origin: AiOrigin.editedPhoto);
    io.cancelSave = true;
    expect(
      await exporter.save(image, bytes, choices: const PhotoMetadataExport()),
      isNull,
    );
    expect(io.saveDialogs, 1);
    expect(codec.writes, isEmpty);
    expect(attachments.metadataLoads, 0);

    io.cancelSave = false;
    final export = await exporter.save(
      image,
      bytes,
      choices: const PhotoMetadataExport(),
    );
    expect(export?.keptOriginal, isTrue);
    expect(io.saved.single.bytes, [7, 7, 7]);
    expect(io.saved.single.mimeType, 'image/png');
  });

  test("keeps all of the original's metadata, into a copy", () async {
    final export = await exporter.prepare(
      block(metadata: photo, origin: AiOrigin.editedPhoto),
      bytes,
      choices: const PhotoMetadataExport(markGeneratedAsAi: false),
    );

    expect(codec.writes.single, (blocks: blocks, mark: null));
    expect(export.keptOriginal, isTrue);
    expect(export.markedAiEdited, isFalse);
    expect(export.bytes, [7, 7, 7]);
    expect(bytes, [1, 2, 3]);
  });

  test('switched off, the file is saved without it, never loaded', () async {
    final export = await exporter.prepare(
      block(metadata: photo, origin: AiOrigin.editedPhoto),
      bytes,
      choices: const PhotoMetadataExport(
        keepOriginal: false,
        markGeneratedAsAi: false,
      ),
    );
    expect(codec.writes.single, (
      blocks: const PhotoMetadataBlocks(),
      mark: null,
    ));
    expect(export.keptOriginal, isFalse);
    expect(attachments.metadataLoads, 0);
  });

  test('an image nothing is known about goes out untouched', () async {
    final export = await exporter.prepare(
      block(),
      bytes,
      choices: const PhotoMetadataExport(),
    );
    expect(codec.writes, isEmpty);
    expect(export.bytes, same(bytes));
    expect(export.keptOriginal, isFalse);
  });

  test("the AI mark: the block's origin, when asked", () async {
    Future<AiOrigin?> markFor({
      required PhotoMetadataRef? metadata,
      required AiOrigin? origin,
      PhotoMetadataExport choices = const PhotoMetadataExport(),
    }) async {
      codec.writes.clear();
      await exporter.prepare(
        block(metadata: metadata, origin: origin),
        bytes,
        choices: choices,
      );
      return codec.writes.singleOrNull?.mark;
    }

    // Read from the block, never guessed from the metadata.
    for (final origin in AiOrigin.values) {
      expect(await markFor(metadata: photo, origin: origin), origin);
      expect(await markFor(metadata: null, origin: origin), origin);
    }
    expect(await markFor(metadata: photo, origin: null), isNull);
    expect(
      await markFor(
        metadata: photo,
        origin: AiOrigin.editedPhoto,
        choices: const PhotoMetadataExport(markGeneratedAsAi: false),
      ),
      isNull,
    );
  });

  test('blocks an earlier build kept in the block are written', () async {
    final export = await exporter.prepare(
      block(
        metadata: const PhotoMetadataRef(summary: shown, inlineBlocks: blocks),
      ),
      bytes,
      choices: const PhotoMetadataExport(),
    );
    expect(codec.writes.single.blocks, blocks);
    expect(export.keptOriginal, isTrue);
  });

  test('a photo attached by the first build is saved without', () async {
    // What is shown was all that build kept.
    final export = await exporter.prepare(
      block(metadata: const PhotoMetadataRef(summary: shown)),
      bytes,
      choices: const PhotoMetadataExport(),
    );
    expect(codec.writes.single.blocks, const PhotoMetadataBlocks());
    expect(export.keptOriginal, isFalse);
  });

  test('a file the codec cannot write into is saved as it is', () async {
    codec.result = null;
    final export = await exporter.prepare(
      block(metadata: photo, origin: AiOrigin.editedPhoto),
      bytes,
      choices: const PhotoMetadataExport(),
    );
    expect(export.bytes, same(bytes));
    expect(export.keptOriginal, isFalse);
    expect(export.markedAiEdited, isFalse);
  });
}
