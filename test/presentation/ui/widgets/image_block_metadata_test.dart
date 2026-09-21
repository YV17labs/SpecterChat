import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/infrastructure/images/exif_photo_metadata_codec.dart';
import 'package:specterchat/presentation/providers/image_reuse_provider.dart';
import 'package:specterchat/presentation/providers/settings_provider.dart';
import 'package:specterchat/presentation/ui/widgets/image_block.dart';

import '../../../support/fakes.dart';
import '../../../support/image_fixtures.dart';
import '../../../support/pump_app.dart';

/// Own file: the engine decode of a real PNG must not share an isolate
/// with other `runAsync` tests (see `image_fixtures.dart`).
void main() {
  // What reading an iPhone photo yields: display fields and the EXIF block.
  final photo = const ExifPhotoMetadataCodec().read(fakeJpegPhoto())!;

  testWidgets("\"Save as…\" writes the photo's metadata, as chosen", (
    tester,
  ) async {
    tester.platformDispatcher.localeTestValue = const Locale('fr', 'FR');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final png = (await tester.runAsync(() => pngFixture(16, 16)))!;
    final harness = TestHarness();
    await harness.attachments.storeBytes(
      attachmentId: 'att',
      messageId: 'm',
      bytes: png,
      mimeType: 'image/png',
    );
    await storePhotoMetadata(harness.attachments, 'meta', blocks: photo.blocks);
    final container = await pumpApp(
      tester,
      SizedBox(
        width: 300,
        height: 300,
        child: ImageBlock(
          block: ImageContentBlock(
            attachmentId: 'att',
            mimeType: 'image/png',
            byteSize: png.length,
            photoMetadata: PhotoMetadataRef(
              summary: photo.summary,
              blocksId: 'meta',
            ),
            aiOrigin: AiOrigin.editedPhoto,
          ),
        ),
      ),
      harness: harness,
    );
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(Image)));
    await tester.pumpAndSettle();
    // The camera shows on hover, the rest in its tooltip — its date in
    // the system's language.
    expect(find.text('iPhone 17'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: find.text('iPhone 17'), matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, contains('5 juil. 2026, 19:41'));

    // A cancelled dialog: nothing was prepared, not even loaded.
    harness.imageIo.cancelSave = true;
    await tester.tap(find.byTooltip('Save as…'));
    await tester.pumpAndSettle();
    expect(harness.imageIo.saveDialogs, 1);
    expect(harness.imageIo.saved, isEmpty);
    expect(harness.attachments.metadataLoads, 0);
    expect(find.byType(SnackBar), findsNothing);
    harness.imageIo.cancelSave = false;

    const codec = ExifPhotoMetadataCodec();
    await tester.tap(find.byTooltip('Save as…'));
    await tester.pumpAndSettle();
    // By default: everything of the photo's, and declared as AI.
    final first = harness.imageIo.saved.single;
    expect(first.mimeType, 'image/png');
    final firstRead = codec.read(first.bytes)!;
    expect(firstRead.blocks.exif, photo.blocks.exif);
    expect(firstRead.summary, photo.summary);
    expect(
      firstRead.blocks.xmp,
      contains('compositeWithTrainedAlgorithmicMedia'),
    );
    expect(
      find.text(
        "Saved with the original photo's metadata, marked as AI-generated",
      ),
      findsOneWidget,
    );
    // The stored attachment is never rewritten.
    expect(harness.attachments.rows['att']!.bytes, png);

    container
        .read(settingsProvider.notifier)
        .updatePhotoMetadata(
          const PhotoMetadataExport(markGeneratedAsAi: false),
        );
    await tester.tap(find.byTooltip('Save as…'));
    await tester.pump(const Duration(seconds: 5)); // first snackbar out
    await tester.pumpAndSettle();
    // Mark switched off: exactly the photo's metadata, nothing added.
    expect(codec.read(harness.imageIo.saved.last.bytes), photo);
    expect(
      find.text("Saved with the original photo's metadata"),
      findsOneWidget,
    );

    // "Annotate & reuse" hands the metadata and origin to the composer.
    await tester.tap(find.byTooltip('Annotate & reuse'));
    await tester.pump();
    expect(container.read(imageReuseProvider)?.metadata, photo);
    expect(container.read(imageReuseProvider)?.aiOrigin, AiOrigin.editedPhoto);
  });
}
