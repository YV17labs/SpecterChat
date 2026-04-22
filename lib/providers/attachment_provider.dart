import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/attachment_repository.dart';
import '../database/i_attachment_repository.dart';
import 'database_provider.dart';

final attachmentRepositoryProvider =
    Provider<IAttachmentRepository>((ref) {
  final database = ref.watch(databaseProvider);
  return AttachmentRepository(database);
});

/// Short grace period kept after the last listener detaches from a
/// per-attachment bytes provider. Scrolling past an image and back
/// within this window hits the Riverpod cache instead of re-reading
/// bytes from SQLite.
const Duration _bytesCacheGrace = Duration(seconds: 30);

/// Decoded bytes for a single attachment, fetched lazily when an
/// [ImageBlock] widget mounts. Released [_bytesCacheGrace] after no
/// widget is watching it — which bounds how long the megabyte-sized
/// byte list stays in RAM without forcing an immediate re-read on
/// brief scroll-outs.
final attachmentBytesProvider =
    FutureProvider.autoDispose.family<Uint8List?, String>((ref, id) async {
  final link = ref.keepAlive();
  Timer? release;
  ref.onCancel(() {
    release = Timer(_bytesCacheGrace, link.close);
  });
  ref.onResume(() {
    release?.cancel();
    release = null;
  });
  ref.onDispose(() => release?.cancel());

  final repo = ref.watch(attachmentRepositoryProvider);
  return repo.loadBytes(id);
});
