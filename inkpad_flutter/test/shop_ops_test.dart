import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/export/dxf_export.dart';
import 'package:inkpad/geometry/make_ops.dart';
import 'package:inkpad/geometry/pathfinder.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/tools/tool.dart';

double mm(double v) => v * 72 / 25.4;

DrawingController make() {
  final c = DrawingController(drawing: InkDrawing(width: mm(800), height: mm(600), units: 'mm'));
  c.setMakeMode(true);
  c.drawing.bitDiameter = mm(6);
  return c;
}

void main() {
  test('offset grows and shrinks shapes exactly', () {
    final r = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 50));
    final out = Pathfinder.offsetShape(r, 10, round: false)!;
    expect(out.bounds.left, closeTo(-10, 0.01));
    expect(out.bounds.width, closeTo(120, 0.01));
    final rounded = Pathfinder.offsetShape(r, 10)!;
    expect(rounded.toFlutterPath().contains(const Offset(-9, -9)), isFalse); // corners rounded
    final inset = Pathfinder.offsetShape(r, -10, round: false)!;
    expect(inset.bounds.width, closeTo(80, 0.01));
    expect(Pathfinder.offsetShape(r, -30), isNull); // nothing left
  });

  test('Offset Path adds a copy with the same cut', () {
    final c = make();
    final p = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.rectangle, const Rect.fromLTWH(10, 10, 100, 100))));
    c.addElement(p);
    c.select(p);
    c.offsetPaths(mm(2));
    expect(c.drawing.allElements.length, 2);
    final copy = c.selection.single as InkStylable;
    expect(copy.cut, p.cut);
    expect(copy.bounds.width, closeTo(100 + 2 * mm(2), 0.05)); // within 0.02 mm
    c.undo();
    expect(c.drawing.allElements.length, 1);
  });

  test('dogbones: ears past a hole\'s corners, notches in a part\'s inside corners', () {
    final slot = InkPath.rect(const Rect.fromLTWH(0, 0, 60, 20));
    final relieved = MakeOps.dogbones(slot, 3, forHole: true)!;
    // Ears reach past the corner along the diagonal: r - r/√2 beyond each edge.
    expect(relieved.bounds.left, closeTo(-(3 - 3 / 1.4142135623730951), 0.05));
    expect(relieved.toFlutterPath().contains(const Offset(-0.5, 0.8)), isTrue);
    expect(MakeOps.dogbones(slot, 3, forHole: false), isNull); // a plain rectangle part has no inside corners
    final tBone = MakeOps.dogbones(slot, 3, forHole: true, tBone: true)!;
    expect(tBone.bounds.left, closeTo(-3, 0.05)); // along the long side: past the short ends
    expect(tBone.bounds.top, closeTo(0, 0.05));

    // An L-shaped part: its one inside corner gets a notch.
    final l = InkPath(nodes: [
      for (final p in const [Offset(0, 0), Offset(60, 0), Offset(60, 20), Offset(20, 20), Offset(20, 60), Offset(0, 60)]) BezierNode.anchor(p),
    ], closed: true);
    final notched = MakeOps.dogbones(l, 3, forHole: false)!;
    expect(notched.toFlutterPath().contains(const Offset(20.5, 20.5)), isFalse);
    expect(notched.toFlutterPath().contains(const Offset(10, 10)), isTrue);
  });

  test('repeat in a grid and around a center', () {
    final c = make();
    final hole = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.ellipse, Rect.fromLTWH(0, 0, mm(5), mm(5)))));
    c.addElement(hole);
    c.select(hole);
    c.repeatGrid(columns: 4, rows: 2, pitchX: mm(32), pitchY: mm(100));
    expect(c.drawing.allElements.length, 8);
    final last = c.drawing.allElements.last as InkPath;
    expect(last.live, isNotNull); // copies keep their dimensions
    expect(last.bounds.left, closeTo(mm(96), 0.001));
    c.selectNone();
    final dot = c.styledPath(InkPath.rect(const Rect.fromLTWH(100, 0, 10, 10)));
    c.addElement(dot);
    c.select(dot);
    c.repeatAround(count: 4, center: const Offset(55, 55), stepDegrees: 90);
    expect(c.selection.length, 4);
  });

  group('box maker', () {
    const t = 12.0;
    final box = BoxMaker(width: 300, depth: 200, height: 150, thickness: t, fingerWidth: 30);

    test('panels have the outer sizes; the front owns the corners', () {
      final panels = {for (final (n, p) in box.panels(gap: 20)) n: p};
      expect(panels.keys, ['Front', 'Back', 'Left', 'Right', 'Bottom']);
      final front = panels['Front']!, left = panels['Left']!, bottom = panels['Bottom']!;
      expect(front.bounds.width, closeTo(300, 1e-6));
      expect(front.bounds.height, closeTo(150, 1e-6));
      expect(left.bounds.width, closeTo(200, 1e-6));
      expect(bottom.bounds.height, closeTo(200, 1e-6));
      bool solid(InkPath p, double x, double y) => p.toFlutterPath().contains(p.bounds.topLeft + Offset(x, y));
      // Bottom corners: the front has the cube, the side and bottom don't.
      expect(solid(front, t / 2, 150 - t / 2), isTrue);
      expect(solid(left, t / 2, 150 - t / 2), isFalse);
      expect(solid(bottom, t / 2, t / 2), isFalse);
      // Open top: the front and sides run straight across.
      expect(solid(front, 150, 1), isTrue);
      expect(solid(left, 100, 1), isTrue);
    });

    test('mating edges interlock: where one has a finger, the other has a notch', () {
      final panels = {for (final (n, p) in box.panels(gap: 20)) n: p};
      final front = panels['Front']!, left = panels['Left']!;
      bool solid(InkPath p, double x, double y) => p.toFlutterPath().contains(p.bounds.topLeft + Offset(x, y));
      // The front's left edge and the left panel's right edge, both along the height.
      for (var y = 2.0; y < 148; y += 3) {
        expect(solid(front, t / 2, y) != solid(left, 200 - t / 2, y), isTrue, reason: 'at height $y');
      }
      // The front's bottom edge and the bottom panel's front edge.
      final bottom = panels['Bottom']!;
      for (var x = 14.0; x < 286; x += 3) {
        expect(solid(front, x, 150 - t / 2) != solid(bottom, 300 - x, 200 - t / 2), isTrue, reason: 'at $x');
      }
    });

    test('makeBox adds cut panels with dogbones', () {
      final c = make();
      c.makeBox(BoxMaker(width: mm(300), depth: mm(200), height: mm(150), thickness: mm(12), fingerWidth: mm(30)));
      final g = c.selection.single as InkGroup;
      expect(g.elements.length, 5);
      final front = g.elements.first as InkStylable;
      expect(front.cut!.type, CutType.exterior);
      expect(front.cut!.depth, closeTo(mm(12), 1e-9));
    });
  });

  group('DXF', () {
    String dxf(InkDrawing d) => String.fromCharCodes(drawingToDxf(d));

    test('true size in mm, y up, layers per cut with depth, real circles and arcs', () {
      final c = make();
      c.drawing.defaultCutDepth = mm(6.35);
      final hole = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.ellipse, Rect.fromLTWH(mm(10), mm(10), mm(8), mm(8)))));
      final panel = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(0, 0, mm(100), mm(50)), cornerRadius: mm(5))));
      c.addElement(panel);
      c.addElement(hole);
      c.select(hole);
      c.setCutType(CutType.pocket);
      c.setCutDepth(mm(3));
      final text = dxf(c.drawing);
      expect(text, contains('AC1009'));
      expect(text, contains('CIRCLE\n8\nPOCKET_D3MM\n10\n14\n20\n586\n30\n0\n40\n4\n'));
      expect(text, contains('EXTERIOR_D6_35MM'));
      expect(RegExp(r'\n42\n-0\.414214\n').allMatches(text).length, 4); // quarter-circle corners as arcs (clockwise)
      expect(RegExp(r'\nVERTEX\n').allMatches(text).length, 8); // a rounded rectangle: 8 vertices
      expect(text.trim().endsWith('EOF'), isTrue);
    });

    test('inches, curves as fine segments, ordinary layers outside Make mode', () {
      final d = InkDrawing(width: 720, height: 720, units: 'in')
        ..activeLayer.elements.add(InkPath.oval(const Rect.fromLTWH(0, 0, 144, 72)));
      final text = dxf(d);
      expect(text, contains('LAYER_1'));
      expect(text, contains(r'$INSUNITS' '\n70\n1\n'));
      expect(RegExp(r'\nVERTEX\n').allMatches(text).length, greaterThan(40));
    });
  });

  test('measuring', () {
    final text = MeasureTool.describe(Offset.zero, Offset(mm(30), -mm(40)), const LengthFormat(unit: 'mm'));
    expect(text, contains('50 mm'));
    expect(text, contains('53.13°'));
    expect(text, contains('↔ 30 mm'));
  });

  group('edge joints', () {
    test('tabs stick out of an edge; slots along a line line up with them', () {
      final c = make();
      final shelf = c.styledPath(InkPath.live(LiveShape.inRect(LiveKind.rectangle, const Rect.fromLTWH(0, 0, 300, 100))));
      c.addElement(shelf);
      // Segment 2 runs along the bottom (bottom-right to bottom-left).
      c.addEdgeJoint(shelf, 2, const EdgeJoint(tabs: true, count: 3, depth: 12, tabWidth: 40));
      final s = c.drawing.allElements.single as InkPath;
      expect(s.live, isNull);
      expect(s.bounds.bottom, closeTo(112, 1e-9));
      bool solid(Offset p) => s.toFlutterPath().contains(p);
      expect(solid(const Offset(50, 106)), isTrue); // a tab (centered at 50)
      expect(solid(const Offset(100, 106)), isFalse); // between tabs
      c.undo();

      final side = InkPath(nodes: [const BezierNode.anchor(Offset(0, 300)), const BezierNode.anchor(Offset(300, 300))]);
      c.addElement(side);
      c.addSlots(side, const SlotRow(count: 3, tabWidth: 40, thickness: 12, clearance: 0.5), dogbones: false);
      final slots = c.selection.cast<InkStylable>().toList();
      expect(slots.length, 3);
      expect(slots.map((x) => x.bounds.center.dx.roundToDouble()), [50, 150, 250]); // where the tabs are
      expect(slots.first.bounds.width, closeTo(40.5, 1e-9));
      expect(slots.first.bounds.height, closeTo(12.5, 1e-9));
      expect(slots.first.cut!.type, CutType.interior);
      expect(side.cut!.type, CutType.guide);
    });

    test('fingers: notches cut in, alternating; dogbones in their corners', () {
      final c = make();
      final part = c.styledPath(InkPath.rect(const Rect.fromLTWH(0, 0, 100, 50)));
      c.addElement(part);
      c.addEdgeJoint(part, 0, const EdgeJoint(tabs: false, count: 5, depth: 10), dogbones: false);
      final p = c.drawing.allElements.single as InkPath;
      bool solid(Offset q) => p.toFlutterPath().contains(q);
      expect(solid(const Offset(10, 5)), isTrue); // first finger
      expect(solid(const Offset(30, 5)), isFalse); // first notch
      expect(solid(const Offset(50, 5)), isTrue);
      expect(solid(const Offset(30, 15)), isTrue); // below the notch
      c.undo();
      c.addEdgeJoint(c.drawing.allElements.single as InkPath, 0, const EdgeJoint(tabs: false, count: 5, depth: 10, startWithFinger: false));
      final q = c.drawing.allElements.single as InkStylable;
      expect(q.toFlutterPath().contains(const Offset(10, 5)), isFalse); // starts with a notch now
      expect(q.toFlutterPath().contains(const Offset(30, 5)), isTrue);
      expect(q.cut, isNotNull); // dogbones kept the cut
    });
  });
}

