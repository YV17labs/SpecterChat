import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decodes [bytes] into a `ui.Image`. The caller owns the result and must
/// `dispose()` it.
Future<ui.Image> decodeUiImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// Rasterises what was recorded into a PNG of the given size and releases
/// the intermediate picture and image.
Future<Uint8List> encodeRecordingAsPng(
  ui.PictureRecorder recorder,
  int width,
  int height,
) async {
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
