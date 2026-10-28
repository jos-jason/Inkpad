import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/export/dxf_export.dart';
import 'package:inkpad/import/dxf_import.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';

double mm(double v) => v * 72 / 25.4;

String dxf(String entities, {int units = 4}) => '0\nSECTION\n2\nHEADER\n9\n\$INSUNITS\n70\n$units\n0\nENDSEC\n'
    '0\nSECTION\n2\nENTITIES\n${entities}0\nENDSEC\n0\nEOF\n';

String line(double x1, double y1, double x2, double y2, [String layer = '0']) =>
    '0\nLINE\n8\n$layer\n10\n$x1\n20\n$y1\n11\n$x2\n21\n$y2\n';

void main() {
  test('loose lines that meet become one closed outline, at true size', () {
    final r = importDxf(dxf(line(0, 0, 100, 0) + line(100, 50, 100, 0) + line(100, 50, 0, 50) + line(0, 0, 0, 50)));
    final shapes = r.drawing.allElements.cast<InkPath>().toList();
    expect(shapes.length, 1);
    final p = shapes.single;
    expect(p.closed, isTrue);
    expect(p.bounds.width, closeTo(mm(100), 1e-9));
    expect(p.bounds.height, closeTo(mm(50), 1e-9));
    expect(p.cut!.type, CutType.exterior);
    expect(r.drawing.makeMode, isTrue);
    expect(r.drawing.units, 'mm');
  });

  test('arcs, bulged polylines, circles and inches', () {
    // A slot: two lines and two half-circle arcs.
    final slot = [
      line(10, 0, 90, 0),
      '0\nARC\n8\n0\n10\n90\n20\n10\n40\n10\n50\n270\n51\n90\n',
      line(90, 20, 10, 20),
      '0\nARC\n8\n0\n10\n10\n20\n10\n40\n10\n50\n90\n51\n270\n',
      '0\nCIRCLE\n8\nPOCKET_D0_25IN\n10\n50\n20\n50\n40\n5\n',
      // A rounded square as a polyline with bulges (quarter circles).
      '0\nLWPOLYLINE\n8\nINTERIOR\n90\n8\n70\n1\n'
          '10\n205\n20\n0\n10\n295\n20\n0\n42\n0.41421356\n10\n300\n20\n5\n10\n300\n20\n95\n42\n0.41421356\n'
          '10\n295\n20\n100\n10\n205\n20\n100\n42\n0.41421356\n10\n200\n20\n95\n10\n200\n20\n5\n42\n0.41421356\n',
    ].join();
    final r = importDxf(dxf(slot, units: 1));
    expect(r.drawing.units, 'in');
    final shapes = r.drawing.allElements.cast<InkPath>().toList();
    final joined = shapes.firstWhere((s) => s.nodes.length > 4 && s.bounds.width < 72 * 101 && s.bounds.height < 72 * 21);
    expect(joined.closed, isTrue);
    expect(joined.bounds.width, closeTo(72 * 100, 0.5));
    expect(joined.bounds.height, closeTo(72 * 20, 0.5));
    final circle = shapes.firstWhere((s) => s.live?.kind == LiveKind.ellipse);
    expect(circle.live!.width, closeTo(72 * 10, 1e-9));
    expect(circle.cut!.type, CutType.pocket);
    expect(circle.cut!.depth, closeTo(18, 1e-9)); // 0.25 in
    final rounded = shapes.firstWhere((s) => s.cut?.type == CutType.interior);
    expect(rounded.bounds.width, closeTo(72 * 100, 0.01));
    expect(rounded.bounds.height, closeTo(72 * 100, 0.01));
    // The corners bulge outwards (the outline stays within its box).
    expect(rounded.toFlutterPath().contains(rounded.bounds.topLeft + const Offset(1, 1)), isFalse);
  });

  test('Inkpad\'s own DXF export reads back', () {
    final c = DrawingController(drawing: InkDrawing(width: mm(400), height: mm(300), units: 'mm'));
    c.setMakeMode(true);
    final panel = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(mm(20), mm(20), mm(200), mm(100)), cornerRadius: mm(8))));
    final hole = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.ellipse, Rect.fromLTWH(mm(50), mm(50), mm(10), mm(10)))));
    c.addElement(panel);
    c.addElement(hole);
    c.select(hole);
    c.setCutType(CutType.interior);
    final back = importDxf(String.fromCharCodes(drawingToDxf(c.drawing))).drawing;
    final shapes = back.allElements.cast<InkPath>().toList();
    final p = shapes.firstWhere((s) => s.cut!.type == CutType.exterior);
    expect(p.bounds.width, closeTo(mm(200), 0.01));
    expect(p.bounds.height, closeTo(mm(100), 0.01));
    final h = shapes.firstWhere((s) => s.cut!.type == CutType.interior);
    expect(h.live!.width, closeTo(mm(10), 1e-6));
    // The hole keeps its place relative to the panel.
    expect(h.bounds.left - p.bounds.left, closeTo(mm(30), 0.01));
  });

  test('blocks, splines and things left out', () {
    final r = importDxf('0\nSECTION\n2\nBLOCKS\n0\nBLOCK\n2\nPEG\n10\n0\n20\n0\n0\nCIRCLE\n8\n0\n10\n0\n20\n0\n40\n2\n0\nENDBLK\n0\nENDSEC\n'
        '0\nSECTION\n2\nENTITIES\n'
        '0\nINSERT\n2\nPEG\n8\nHOLES\n10\n10\n20\n10\n'
        '0\nINSERT\n2\nPEG\n8\nHOLES\n10\n40\n20\n10\n41\n2\n42\n2\n'
        '0\nSPLINE\n8\n0\n71\n3\n72\n8\n73\n4\n40\n0\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n40\n1\n10\n0\n20\n0\n10\n10\n20\n20\n10\n20\n20\n20\n10\n30\n20\n0\n'
        '0\nTEXT\n8\n0\n1\nhello\n0\nENDSEC\n0\nEOF\n');
    final shapes = r.drawing.allElements.cast<InkPath>().toList();
    final circles = shapes.where((s) => s.live != null).toList();
    expect(circles.map((s) => s.live!.width.round()), [mm(4).round(), mm(8).round()]); // scaled block
    expect(r.drawing.layers.map((l) => l.name), containsAll(['HOLES']));
    final spline = shapes.firstWhere((s) => s.live == null);
    expect(spline.bounds.width, closeTo(mm(30), 0.01));
    expect(r.warnings.join(), contains('text'));
  });

  test('not a DXF', () {
    expect(() => importDxf('hello'), throwsA(isA<DxfImportException>()));
  });
}
