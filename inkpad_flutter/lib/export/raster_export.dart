import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../model/drawing.dart';
import '../model/element.dart';
import '../text/font_library.dart';

/// Loads what drawing needs before an export: decoded images and the
/// fonts the text uses (otherwise they'd come out blank or in the
/// fallback font).
Future<void> prepareForExport(InkDrawing d) async {
  for (final image in d.images) {
    await image.ensureDecoded();
  }
  final fonts = <(String, String)>{};
  for (final e in d.allElements) {
    for (final x in e.selfAndDescendants) {
      if (x is InkText) fonts.add((x.fontFamily, x.fontStyle));
      if (x is InkTextPath) fonts.add((x.fontFamily, x.fontStyle));
    }
  }
  for (final (family, style) in fonts) {
    await FontLibrary.instance.loadFace(family, style);
  }
}

/// The largest PNG side we'll make (GPU texture limits).
const maxPngSide = 16384;

/// The drawing's page as a PNG at [scale] (1 = one pixel per point).
/// Ported in spirit from -[WDDrawing image]: everything on visible layers,
/// on white unless [transparent].
Future<Uint8List> drawingToPng(InkDrawing d, {double scale = 1, bool transparent = false}) async {
  await prepareForExport(d);
  final s = math.min(scale, maxPngSide / math.max(d.width, d.height));
  final w = math.max(1, (d.width * s).round()), h = math.max(1, (d.height * s).round());
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  if (!transparent) canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  canvas.scale(s);
  canvas.clipRect(d.bounds);
  d.render(canvas, d.bounds);
  final image = await rec.endRecording().toImage(w, h);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}
