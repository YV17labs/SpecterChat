import 'dart:typed_data';

import '../models/message.dart';

/// A file the user offered (dialog or drop): its display name and a way to
/// read it. Reading is deferred so a file refused by name costs nothing.
typedef ImageFileSource = ({String name, Future<Uint8List> Function() read});

/// The desktop's image exchange points: file dialogs and the clipboard.
///
/// Widgets never touch the platform plugins directly; they go through this
/// contract so the flows (attach, paste, save, copy) can be driven by a
/// fake in tests.
abstract interface class IImageIo {
  /// Opens the platform file dialog filtered on raster images. Empty when
  /// the user cancels. Nothing is validated here — that is the normaliser's
  /// job.
  Future<List<ImageFileSource>> pickImages();

  /// Asks where to save [image] and writes it. `false` when the user
  /// cancelled the dialog.
  Future<bool> saveImage(ImageBytes image);

  /// The image on the clipboard, if there is one.
  Future<Uint8List?> readClipboardImage();

  Future<void> writeClipboardImage(Uint8List bytes);
}
