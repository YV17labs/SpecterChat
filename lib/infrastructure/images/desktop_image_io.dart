import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../core/image_mime.dart';
import '../../domain/services/i_image_io.dart';
import '../files/desktop_file_saver.dart';

/// [IImageIo] on the desktop plugins: `file_selector` for the dialogs,
/// `pasteboard` for image clipboard access. macOS needs the
/// `files.user-selected.read-write` entitlement for the dialogs.
class DesktopImageIo implements IImageIo {
  const DesktopImageIo();

  @override
  Future<List<ImageFileSource>> pickImages() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Images',
          extensions: kImageExtensions,
          uniformTypeIdentifiers: const ['public.image'],
          mimeTypes: kImageMimeTypes,
        ),
      ],
    );
    return [
      for (final file in files) (name: file.name, read: file.readAsBytes),
    ];
  }

  @override
  Future<bool> saveImage({
    required String mimeType,
    required Future<Uint8List> Function() contents,
  }) {
    final ext = extensionForMime(mimeType);
    return const DesktopFileSaver().save(
      suggestedName: 'image.$ext',
      typeLabel: 'Image',
      extension: ext,
      mimeType: mimeType,
      contents: contents,
    );
  }

  @override
  Future<Uint8List?> readClipboardImage() async {
    final image = await Pasteboard.image;
    return image == null || image.isEmpty ? null : image;
  }

  @override
  Future<void> writeClipboardImage(Uint8List bytes) =>
      Pasteboard.writeImage(bytes);
}
