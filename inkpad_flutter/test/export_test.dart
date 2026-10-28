import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/export/pdf_export.dart';
import 'package:inkpad/export/raster_export.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';

import 'helpers/test_fonts.dart';

Future<Uint8List> pngOf(Color color, int w, int h) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = color);
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<(ui.Image, ByteData)> decode(Uint8List png) async {
  final img = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
  return (img, (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!);
}

/// A drawing with one of everything the PDF writer handles.
Future<InkDrawing> sampler() async {
  final photo = ImageData.register(await pngOf(const Color(0xFF00AA00), 8, 4))!;
  final mask = InkPath.oval(const Rect.fromLTWH(220, 20, 60, 60))..fill = const InkColor(1, 1, 0);
  mask.maskedElements = [InkPath.rect(const Rect.fromLTWH(200, 40, 100, 20))..fill = const InkColor(0, 0, 1)];
  return InkDrawing(width: 300, height: 200)
    ..activeLayer.elements.addAll([
      InkPath.rect(const Rect.fromLTWH(10, 10, 80, 60))
        ..fill = InkGradient.between(const InkColor(1, 0, 0), const InkColor(0, 0, 1))
        ..stroke = const StrokeStyle(width: 3, dashPattern: [6, 3])
        ..shadow = const InkShadow(offset: 6)
        ..opacity = 0.8,
      InkPath.oval(const Rect.fromLTWH(110, 10, 80, 80))
        ..fill = InkGradient.between(const InkColor(1, 1, 1), const InkColor(0, 0.5, 0), type: GradientType.radial)
        ..blendMode = InkBlendMode.multiply,
      InkPath(nodes: [const BezierNode.anchor(Offset(10, 120)), const BezierNode.anchor(Offset(150, 120))],
          stroke: const StrokeStyle(width: 4, endArrow: 'arrow1', color: InkColor(0.2, 0.2, 0.2, 0.5))),
      InkText(text: 'Inkpad', fontFamily: 'Lato', fontSize: 30, placement: Affine.translation(170, 160), fill: InkColor.black),
      InkImage(photo, placement: Affine(10, 0, 0, 10, 10, 140)),
      mask,
    ]);
}

void main() {
  setUpAll(initTestFonts);

  test('PNG: the page at the chosen scale, on white or transparent', () async {
    final d = InkDrawing(width: 100, height: 50)
      ..activeLayer.elements.add(InkPath.rect(const Rect.fromLTWH(10, 10, 30, 30))..fill = const InkColor(1, 0, 0));
    final (img, px) = await decode(await drawingToPng(d, scale: 2));
    expect((img.width, img.height), (200, 100));
    int at(int x, int y, int c) => px.getUint8((y * 200 + x) * 4 + c);
    expect([at(50, 50, 0), at(50, 50, 1), at(50, 50, 3)], [255, 0, 255]);
    expect([at(150, 50, 0), at(150, 50, 1), at(150, 50, 3)], [255, 255, 255]);
    final (_, clear) = await decode(await drawingToPng(d, transparent: true));
    expect(clear.getUint8((25 * 100 + 80) * 4 + 3), 0);
  });

  test('PNG: hidden layers are left out; huge pages are capped', () async {
    final d = InkDrawing(width: 20, height: 20)
      ..activeLayer.elements.add(InkPath.rect(const Rect.fromLTWH(0, 0, 20, 20))..fill = const InkColor(1, 0, 0))
      ..activeLayer.visible = false;
    final (_, px) = await decode(await drawingToPng(d));
    expect(px.getUint8(1), 255); // white, not red
    final big = InkDrawing(width: 10000, height: 100);
    final (img, _) = await decode(await drawingToPng(big, scale: 4));
    expect(img.width, maxPngSide);
  });

  test('PDF: one page the size of the drawing, with vector paint', () async {
    final d = await sampler();
    final pdf = await drawingToPdf(d, compress: false);
    final text = latin1.decode(pdf);
    expect(text.startsWith('%PDF-'), isTrue);
    expect(text, contains('/MediaBox[0 0 300 200]'));
    expect(RegExp(r'/Type/Page\b').allMatches(text).length, 1);
    expect(text, contains('/ShadingType 2')); // linear gradient
    expect(text, contains('/ShadingType 3')); // radial gradient
    expect(text, contains('/BM/Multiply'));
    expect(text, contains('/Subtype/Image'));
    expect(text, contains('[6 3] 0 d')); // the dash pattern
    expect(text, contains(' W n')); // clipping for the gradient and the mask
    // Compressed by default.
    expect((await drawingToPdf(d)).length, lessThan(pdf.length));
  });
}
