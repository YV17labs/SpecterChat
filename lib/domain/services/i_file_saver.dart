import 'dart:typed_data';

/// The desktop's "Save as…" dialog, for files that are not images (those
/// go through `IImageIo.saveImage`).
abstract interface class IFileSaver {
  /// Asks where to save a file, proposing [suggestedName] and filtering on
  /// [extension] (shown as [typeLabel]), then writes there what [contents]
  /// produces — called only once a place was chosen, so nothing is
  /// prepared for a dialog the user cancels. `false` when the user
  /// cancelled.
  Future<bool> save({
    required String suggestedName,
    required String typeLabel,
    required String extension,
    required String mimeType,
    required Future<Uint8List> Function() contents,
  });
}
