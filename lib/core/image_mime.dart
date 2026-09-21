import 'dart:typed_data';

/// Raster formats the app accepts, as the model servers accept them, with
/// the extension a saved file gets. The single table every other list here
/// derives from.
const Map<String, String> kImageExtensionByMime = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'image/gif': 'gif',
};

final List<String> kImageMimeTypes = kImageExtensionByMime.keys.toList(
  growable: false,
);

/// File extensions for dialog filters and drag-and-drop pre-checks — the
/// canonical ones plus the JPEG alias.
final List<String> kImageExtensions = [...kImageExtensionByMime.values, 'jpeg'];

/// Extension for a saved file of type [mime]; PNG when unknown.
String extensionForMime(String mime) => kImageExtensionByMime[mime] ?? 'png';

/// MIME type from the file's magic bytes — never from its extension, which
/// drag-and-drop and clipboard sources routinely get wrong. `null` when the
/// bytes are not one of [kImageMimeTypes].
String? sniffImageMime(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 6 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x38) {
    return 'image/gif';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}
