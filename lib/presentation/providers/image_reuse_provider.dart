import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/images/stored_photo_metadata.dart';
import '../../domain/models/message.dart'
    show DescribedImage, ImageContentBlock;
import 'database_provider.dart';

/// An image already shown in the conversation (typically a generated
/// result) that the user wants to annotate and send again, with what is
/// known about it — its photo metadata, so an edit of an edit still
/// inherits it, and how a model made it. Producers (`ImageBlock`) call
/// [ImageReuse.request]; `ChatComposer` attaches it as a pending image,
/// opens the annotation editor, then calls [ImageReuse.consume]. Same
/// one-shot channel as `chatInputInjectionProvider`, for the same reason: a
/// bubble deep in the list must not know the composer.
final imageReuseProvider = NotifierProvider<ImageReuse, DescribedImage?>(
  ImageReuse.new,
);

class ImageReuse extends Notifier<DescribedImage?> {
  @override
  DescribedImage? build() => null;

  /// Reuse [block], whose stored bytes are [bytes]. Its photo metadata's
  /// blocks are loaded now: the block itself keeps only what is shown.
  Future<void> request(ImageContentBlock block, Uint8List bytes) async {
    final image = await describeStoredImage(
      ref.read(attachmentRepositoryProvider),
      block,
      bytes,
    );
    if (ref.mounted) state = image;
  }

  void consume() => state = null;
}
