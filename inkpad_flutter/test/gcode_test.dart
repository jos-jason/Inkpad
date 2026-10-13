import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/export/gcode.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';

double mm(double v) => v * 72 / 25.4;

DrawingController job() {
  final c = DrawingController(drawing: InkDrawing(width: mm(300), height: mm(200), units: 'mm'));
  c.setMakeMode(true);
  c.drawing
    ..bitDiameter = mm(6)
    ..materialThickness = mm(12)
    ..defaultCutDepth = mm(12);
  c.drawing.cam
    ..stepDown = mm(4)
    ..tabHeight = mm(2)
    ..tabCount = 2;
  return c;
}

void main() {
  test('a part cut out in passes, with tabs, after its pocket', () {
    final c = job();
    final part = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(mm(20), mm(20), mm(100), mm(60)))));
    final pocket = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(mm(40), mm(40), mm(30), mm(20)))));
    c.addElement(part);
    c.addElement(pocket);
    c.select(pocket);
    c.setCutType(CutType.pocket);
    c.setCutDepth(mm(3));
    final p = makeGcode(c.drawing, c.drawing.cam, title: 'Test');
    final code = p.code;
    expect(code, contains('G21'));
    expect(code, contains('M3 S18000'));
    expect(code.trim().endsWith('M2'), isTrue);
    // Depths: the pocket at -3, the part in passes to -12, tabs at -10.
    expect(code, contains('Z-3'));
    for (final z in ['Z-4 ', 'Z-8 ', 'Z-12 ', 'Z-10']) {
      expect(code, contains(z), reason: z);
    }
    // The pocket is cut before the part.
    expect(code.indexOf('Z-3'), lessThan(code.indexOf('Z-12')));
    // The part's outline is offset by the bit's radius (3 mm): x from 17 to 123.
    expect(code, contains('X17 '));
    expect(code, contains('X123 '));
    // Y measured up from the page's bottom: the part's top (y 20) is 177 mm up (plus 3).
    expect(code, contains('Y183'));
    expect(p.minutes, greaterThan(0));
  });

  test('inches, climb milling, and holes too small for the bit', () {
    final c = job();
    c.drawing.units = 'in';
    final hole = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.ellipse, Rect.fromLTWH(mm(50), mm(50), mm(4), mm(4)))));
    c.addElement(hole);
    c.select(hole);
    c.setCutType(CutType.interior);
    final p = makeGcode(c.drawing, c.drawing.cam);
    expect(p.code, contains('G20'));
    expect(p.notes.single, contains('too small'));

    final square = InkPath.rect(Rect.fromLTWH(mm(10), mm(10), mm(50), mm(50)));
    DrawingController.applyCut(square, const CutSpec(CutType.exterior));
    final d = InkDrawing(width: mm(100), height: mm(100))
      ..makeMode = true
      ..bitDiameter = mm(6);
    d.activeLayer.elements.add(square);
    // The first cutting move's direction differs between climb and conventional.
    Offset firstStep(bool climb) {
      final moves = makeGcode(d, CamSettings(climb: climb, tabs: false)).moves.where((m) => !m.rapid).toList();
      return moves[2].at - moves[1].at;
    }

    final conventional = firstStep(false), climb = firstStep(true);
    expect(conventional.dx * climb.dx + conventional.dy * climb.dy, lessThan(0));
  });

  test('settings are kept with the drawing', () {
    final d = InkDrawing()
      ..cam.feed = 1500
      ..cam.tabs = false;
    final back = InkDrawing.decode(d.encode());
    expect((back.cam.feed, back.cam.tabs), (1500, false));
  });
}
