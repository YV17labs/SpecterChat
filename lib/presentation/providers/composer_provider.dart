import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/images/drawing_session.dart' show AnnotationResult;
import '../../application/images/pending_image.dart';
import '../../core/id_gen.dart';
import '../../domain/models/message.dart' show DescribedImage;
import 'image_providers.dart';

/// Outcome of [ComposerNotifier.attach]. The widget turns refusals into
/// messages; the notifier stays free of UI strings.
sealed class AttachResult {
  const AttachResult();
}

class Attached extends AttachResult {
  final String id;
  const Attached(this.id);
}

/// The message already carries [kMaxPendingImages] outgoing images.
class NoRoomForImage extends AttachResult {
  const NoRoomForImage();
}

/// The bytes are not a supported image.
class UnsupportedImage extends AttachResult {
  const UnsupportedImage();
}

/// The images attached to the message being composed for one conversation.
///
/// Auto-disposed with the conversation view, so switching away drops the
/// draft — it belongs to that composer only. The text lives in the widget's
/// `TextEditingController`; only what needs logic (slots, annotations,
/// validation) is here.
final composerProvider = NotifierProvider.autoDispose
    .family<ComposerNotifier, List<PendingImage>, String>(ComposerNotifier.new);

class ComposerNotifier extends Notifier<List<PendingImage>> {
  ComposerNotifier(String _);

  @override
  List<PendingImage> build() => const [];

  /// Images the message can still take (annotations may expand one entry
  /// into up to three outgoing images).
  int get freeSlots => freeImageSlots(state);

  /// Slots available to the editor of [id]: the ones its own extras already
  /// occupy are free to re-use.
  int freeSlotsFor(String id) {
    final image = find(id);
    return freeSlots + (image == null ? 0 : image.outgoingCount - 1);
  }

  PendingImage? find(String id) {
    for (final image in state) {
      if (image.id == id) return image;
    }
    return null;
  }

  /// Validate, downscale and queue [bytes] under [name]. The photo's
  /// metadata is read from [bytes] before the normaliser may re-encode it
  /// away — unless they are those of [reused], an image of the
  /// conversation: what its block knows comes along instead (its stored
  /// bytes are not the photo's file).
  Future<AttachResult> attach(
    Uint8List bytes, {
    required String name,
    DescribedImage? reused,
  }) async {
    if (freeSlots <= 0) return const NoRoomForImage();
    final metadata = reused == null
        ? ref.read(photoMetadataCodecProvider).read(bytes)
        : reused.metadata;
    final prepared = await ref.read(imageNormalizerProvider).normalize(bytes);
    if (!ref.mounted) return const NoRoomForImage();
    if (prepared == null) return const UnsupportedImage();
    // Re-check: another attach may have landed while we were decoding.
    if (freeSlots <= 0) return const NoRoomForImage();
    final id = generateId();
    state = [
      ...state,
      PendingImage(
        id: id,
        name: name,
        image: DescribedImage(
          bytes: prepared.bytes,
          mimeType: prepared.mimeType,
          metadata: metadata,
          aiOrigin: reused?.aiOrigin,
        ),
      ),
    ];
    return Attached(id);
  }

  void remove(String id) => state = [
    for (final i in state)
      if (i.id != id) i,
  ];

  /// Store what the annotation editor returned for [id]. An empty
  /// annotation clears it, so the thumbnail goes back to plain.
  void applyAnnotation(String id, AnnotationResult result) => state = [
    for (final i in state) i.id == id ? i.withAnnotation(result) : i,
  ];

  /// Empties the composer and hands back what it held, for sending.
  List<PendingImage> take() {
    final images = state;
    state = const [];
    return images;
  }

  /// Puts a draft back after a failed send.
  void restore(List<PendingImage> images) => state = images;
}
