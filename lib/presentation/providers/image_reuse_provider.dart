import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/photo_metadata.dart';

/// An image already shown in the conversation (typically a generated
/// result) that the user wants to annotate and send again. Producers
/// (`ImageBlock`) set it; `ChatComposer` attaches the bytes as a pending
/// image, opens the annotation editor, then calls [ImageReuse.consume].
/// Same one-shot channel as `chatInputInjectionProvider`, for the same
/// reason: a bubble deep in the list must not know the composer.
class ImageReuseRequest {
  final Uint8List bytes;
  final String mimeType;

  /// The image's photo metadata, so an edit of an edit still inherits it.
  final PhotoMetadata? metadata;

  const ImageReuseRequest({
    required this.bytes,
    required this.mimeType,
    this.metadata,
  });
}

final imageReuseProvider = NotifierProvider<ImageReuse, ImageReuseRequest?>(
  ImageReuse.new,
);

class ImageReuse extends Notifier<ImageReuseRequest?> {
  @override
  ImageReuseRequest? build() => null;

  void request(Uint8List bytes, String mimeType, {PhotoMetadata? metadata}) =>
      state = ImageReuseRequest(
        bytes: bytes,
        mimeType: mimeType,
        metadata: metadata,
      );

  void consume() => state = null;
}
