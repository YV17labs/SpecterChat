import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:specterchat/presentation/rendering/ui_image_codec.dart';

/// A flat PNG of the given size, so decoders and `Image.memory` are
/// exercised for real rather than with placeholder bytes. Engine work is
/// real async: callers wrap it in `tester.runAsync`. A test file that
/// leaves an `Image.memory` decode pending stalls `runAsync` in the same
/// isolate, so engine-heavy tests keep their own file.
Future<Uint8List> pngFixture(
  int width,
  int height, {
  ui.Color color = const ui.Color(0xFF808080),
}) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = color,
  );
  return encodeRecordingAsPng(recorder, width, height);
}

/// A decoded flat image. The caller owns it and must `dispose()` it.
Future<ui.Image> uiImageFixture(int width, int height) async =>
    decodeUiImage(await pngFixture(width, height));

/// RGB of one pixel of a PNG.
Future<List<int>> pngPixel(Uint8List png, int x, int y) async {
  final image = await decodeUiImage(png);
  final raw = (await image.toByteData())!;
  final i = (y * image.width + x) * 4;
  image.dispose();
  return [raw.getUint8(i), raw.getUint8(i + 1), raw.getUint8(i + 2)];
}

/// `(width, height)` of a PNG.
Future<(int, int)> pngSize(Uint8List png) async {
  final image = await decodeUiImage(png);
  final s = (image.width, image.height);
  image.dispose();
  return s;
}
