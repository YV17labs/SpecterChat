import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/images/image_export.dart';
import '../../domain/services/i_annotation_renderer.dart';
import '../../domain/services/i_image_io.dart';
import '../../domain/services/i_image_normalizer.dart';
import '../../domain/services/i_photo_metadata_codec.dart';
import '../../infrastructure/images/desktop_image_io.dart';
import '../../infrastructure/images/exif_photo_metadata_codec.dart';
import '../../infrastructure/images/ui_image_normalizer.dart';
import '../rendering/ui_annotation_renderer.dart';
import 'database_provider.dart';

/// Validates and downscales images before they are attached. Override in
/// tests with a pass-through fake: the real one decodes on the engine.
final imageNormalizerProvider = Provider<IImageNormalizer>(
  (_) => const UiImageNormalizer(),
);

/// Renders annotated copies and masks at send time.
final annotationRendererProvider = Provider<IAnnotationRenderer>(
  (_) => const UiAnnotationRenderer(),
);

/// File dialogs and image clipboard. Override in tests to script what the
/// user "picks" or "pastes".
final imageIoProvider = Provider<IImageIo>((_) => const DesktopImageIo());

/// Reads a photo's metadata when it is attached, writes it back on save.
final photoMetadataCodecProvider = Provider<IPhotoMetadataCodec>(
  (_) => const ExifPhotoMetadataCodec(),
);

/// "Save as…": the image with the photo metadata the user chose to keep,
/// loaded from its attachment, written where the user says.
final imageExporterProvider = Provider<ImageExporter>(
  (ref) => ImageExporter(
    ref.watch(photoMetadataCodecProvider),
    ref.watch(attachmentRepositoryProvider),
    ref.watch(imageIoProvider),
  ),
);
