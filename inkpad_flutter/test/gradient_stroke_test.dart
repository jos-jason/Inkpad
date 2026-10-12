import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/export/pdf_export.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/svg/svg_importer.dart';

import 'helpers/test_fonts.dart';

const red = InkColor(1, 0, 0), blue = InkColor(0, 0, 1);

InkPath gradientLine({String endArrow = ''}) => InkPath(
      nodes: [const BezierNode.anchor(Offset(10, 50)), const BezierNode.anchor(Offset(90, 50))],
      stroke: StrokeStyle(width: 10, cap: LineCap.butt, endArrow: endArrow).withPaint(InkGradient.between(red, blue)),
    );

void main() {
  setUpAll(initTestFonts);

  test('withPaint switches between a color and a gradient', () {
    final s = const StrokeStyle(width: 3).withPaint(InkGradient.between(red, blue));
    expect(s.gradient, isNotNull);
    expect(s.paint, isA<InkGradient>());
    expect(s.withPaint(red).gradient, isNull);
    expect(s.withPaint(red).color, red);
    expect(StrokeStyle.fromJson(jsonDecode(jsonEncode(s.toJson()))).gradient!.stops.last.color, blue);
  });

  test('the outline is painted with the gradient along the shape', () async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = const Color(0xFFFFFFFF));
    gradientLine().render(canvas);
    final img = await rec.endRecording().toImage(100, 100);
    final d = (await img.toByteData())!;
    int px(int x, int c) => d.getUint8((50 * 100 + x) * 4 + c);
    expect(px(12, 0), greaterThan(200)); // red end
    expect(px(12, 2), lessThan(60));
    expect(px(88, 2), greaterThan(200)); // blue end
    expect(px(88, 0), lessThan(60));
  });

  test('the gradient turns with the shape', () {
    final p = gradientLine()..transform(Affine.rotationAbout(const Offset(50, 50), 1.5707963));
    final g = p.stroke!.gradient!.geometry!;
    expect(g.documentStart.dx, closeTo(50, 0.01));
    expect(g.documentEnd.dy, closeTo(90, 0.01));
  });

  test('SVG export and import keep the gradient, also on arrowheads', () {
    final p = gradientLine(endArrow: 'arrow1');
    final svg = (InkDrawing()..activeLayer.elements.addAll([gradientLine(), p])).toSvg();
    expect(svg, contains('stroke="url(#gradient1)"'));
    expect(svg, contains('<linearGradient id="gradient1"'));
    expect(RegExp(r'fill="url\(#gradient\d\)" fill-rule="evenodd"').hasMatch(svg), isTrue); // the arrowhead
    final back = importSvg(svg);
    expect(back.warnings.join(), isNot(contains('Gradient outlines')));
    final paths = back.drawing.allElements.cast<InkPath>().toList();
    for (final q in paths) {
      final g = q.stroke!.gradient!;
      expect(g.stops.first.color, red);
      expect(g.stops.last.color, blue);
      expect(g.fitted(q.bounds).documentStart.dx, closeTo(10, 0.01));
    }
    expect(paths.last.stroke!.endArrow, 'arrow1');
  });

  test('color menu, Outline Stroke and the eyedropper handle it', () {
    final p = gradientLine();
    final c = DrawingController()..addElement(p);
    c.select(p);
    c.invertColors();
    expect(p.stroke!.gradient!.stops.first.color, const InkColor(0, 1, 1));
    c.outlineStroke();
    final outline = c.drawing.allElements.single as InkStylable;
    expect(outline.fill, isA<InkGradient>());
    // Fitted to the original line, not the (taller) outline.
    expect((outline.fill as InkGradient).geometry!.documentStart, const Offset(10, 50));

    // Picking a shape up with a gradient outline: the gradient fits the next shape.
    final moved = gradientLine()..transform(Affine.translation(0, 100));
    c.addElement(moved);
    c.select(moved);
    expect(c.strokeStyle!.gradient!.geometry, isNull);
  });

  test('PDF fills the outline with a shading', () async {
    final pdf = latin1.decode(await drawingToPdf(InkDrawing(width: 100, height: 100)..activeLayer.elements.add(gradientLine()), compress: false));
    expect(pdf, contains('/ShadingType 2'));
  });
}
