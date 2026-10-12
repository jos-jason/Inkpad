import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';

import 'helpers/test_fonts.dart';

DrawingController controllerWith(List<InkElement> elements, {bool points = false, bool edges = false, bool grid = false}) {
  final c = DrawingController(drawing: InkDrawing(width: 400, height: 400));
  c.drawing
    ..snapToPoints = points
    ..snapToEdges = edges
    ..snapToGrid = grid;
  for (final e in elements) {
    c.addElement(e);
  }
  return c;
}

InkPath square(double x, double y, [double size = 50]) => InkPath.rect(Rect.fromLTWH(x, y, size, size))..fill = InkColor.black;

/// Runs a drag with [tool] at 100% zoom (mouse: 10 px snap reach).
void drag(DrawingController c, Tool tool, Offset from, Offset to, {int steps = 4}) {
  c.tool = tool;
  tool.begin(c, ToolEvent(from, 1));
  for (var i = 1; i <= steps; i++) {
    tool.move(c, ToolEvent(Offset.lerp(from, to, i / steps)!, 1));
  }
  tool.end(c, ToolEvent(to, 1));
}

void main() {
  setUpAll(initTestFonts);

  group('snap search', () {
    test('nothing snaps when snapping is off', () {
      final c = controllerWith([square(100, 100)]);
      expect(c.snap(const Offset(103, 102), 10).snapped, isFalse);
    });

    test('points come first, then edges, then the page; nearest wins', () {
      final c = controllerWith([square(100, 100), square(103, 160)], points: true, edges: true);
      final r = c.snap(const Offset(104, 103), 10);
      expect((r.kind, r.point), (SnapKind.point, const Offset(100, 100)));
      final edge = c.snap(const Offset(125, 104), 10);
      expect((edge.kind, edge.point), (SnapKind.edge, const Offset(125, 100)));
      // The page's corners and edges.
      expect(c.snap(const Offset(395, 397), 10).point, const Offset(400, 400));
      expect((c.snap(const Offset(250, 3), 10).point - const Offset(250, 0)).distance, lessThan(1e-6));
      // Out of reach.
      expect(c.snap(const Offset(250, 250), 10).snapped, isFalse);
    });

    test('edges follow curves', () {
      final circle = InkPath.oval(const Rect.fromLTWH(100, 100, 100, 100));
      final c = controllerWith([circle], edges: true);
      final r = c.snap(const Offset(150, 96), 10);
      expect(r.kind, SnapKind.edge);
      expect(r.point.dx, closeTo(150, 0.5));
      expect(r.point.dy, closeTo(100, 0.5));
    });

    test('groups, compound paths, images and text are targets; skipped things are not', () {
      final inGroup = square(200, 200);
      final c = controllerWith([InkGroup([inGroup]), InkCompoundPath([square(10, 300)])], points: true);
      expect(c.snap(const Offset(202, 203), 10).point, const Offset(200, 200));
      expect(c.snap(const Offset(12, 303), 10).point, const Offset(10, 300));
      expect(c.snap(const Offset(202, 203), 10, skip: (e) => e is InkGroup).snapped, isFalse);
      expect(c.snap(const Offset(202, 203), 10, skipNode: (p, i) => identical(p, inGroup) && i == 0).snapped, isFalse);
      final text = InkText(text: 'Hi', fontFamily: 'Lato', width: 100, placement: Affine.translation(300, 20));
      final c2 = controllerWith([text], points: true);
      expect(c2.snap(const Offset(303, 22), 10).point, const Offset(300, 20));
    });

    test('grid rounds to the nearest intersection, always', () {
      final c = controllerWith([], grid: true)..drawing.gridSpacing = 20;
      expect(c.snap(const Offset(31, 49), 10).point, const Offset(40, 40));
      expect(c.snap(const Offset(31, 49), 10).kind, SnapKind.grid);
      expect(c.snap(const Offset(31, 49), 10, grid: false).snapped, isFalse);
      // The selection's nearest corner lands on the grid.
      expect(c.gridOffset(const Rect.fromLTWH(3, 3, 50, 50), const Offset(10, 0)), const Offset(7, -3)); // top-right corner is nearest
    });

    test('settings are saved with the drawing', () {
      final d = InkDrawing()
        ..snapToEdges = true
        ..showGrid = true
        ..gridSpacing = 18;
      final back = InkDrawing.decode(d.encode());
      expect((back.snapToPoints, back.snapToEdges, back.snapToGrid, back.showGrid, back.gridSpacing), (false, true, false, true, 18));
      // Older drawings: Inkpad's defaults.
      final old = InkDrawing.fromJson(InkDrawing().toJson()..remove('snap')..remove('grid'));
      expect((old.snapToGrid, old.gridSpacing), (false, 36));
    });
  });

  group('tools', () {
    test('shapes start and end on the grid', () {
      final c = controllerWith([], grid: true);
      drag(c, ShapeTool(ShapeKind.rectangle), const Offset(40, 30), const Offset(70, 75));
      expect(c.drawing.allElements.single.bounds, const Rect.fromLTRB(36, 36, 72, 72));
    });

    test('a line ends on another shape\'s point', () {
      final c = controllerWith([square(100, 100)], points: true);
      drag(c, ShapeTool(ShapeKind.line), const Offset(10, 10), const Offset(146, 154));
      final line = c.drawing.allElements.last as InkPath;
      expect(line.nodes.last.anchorPoint, const Offset(150, 150));
    });

    test('moving a shape: its grabbed corner snaps to another point', () {
      final other = square(200, 200), mover = square(0, 0);
      final c = controllerWith([other, mover], points: true);
      c.select(mover);
      // Grab the mover's bottom-right corner and drop it near the other's top-left.
      drag(c, SelectionTool(), const Offset(49, 49), const Offset(196, 203));
      expect(mover.bounds.bottomRight, const Offset(200, 200));
    });

    test('moving a shape on the grid snaps its nearest corner', () {
      final mover = square(3, 3);
      final c = controllerWith([mover], grid: true)..drawing.gridSpacing = 20;
      c.select(mover);
      drag(c, SelectionTool(), const Offset(25, 25), const Offset(36, 26));
      expect(mover.bounds.topLeft, const Offset(10, 0)); // its top-right corner lands on (60, 0)
      c.undo();
      expect((c.drawing.allElements.single as InkPath).bounds.topLeft, const Offset(3, 3));
    });

    test('a dragged point snaps to others but not to itself', () {
      final target = square(100, 100), mover = square(0, 0);
      final c = controllerWith([target, mover], points: true, edges: true);
      c.select(mover);
      // Small moves away from its own position aren't held back.
      drag(c, SelectionTool(), const Offset(50, 50), const Offset(58, 53));
      expect(mover.nodes[2].anchorPoint, const Offset(58, 53));
      drag(c, SelectionTool(), const Offset(58, 53), const Offset(97, 104));
      expect(mover.nodes[2].anchorPoint, const Offset(100, 100));
      expect(c.snapFeedback?.kind, SnapKind.point);
    });

    test('direct select drags several points, snapping the one grabbed', () {
      final mover = InkPath(nodes: [const BezierNode.anchor(Offset(10, 10)), const BezierNode.anchor(Offset(30, 10))]);
      final c = controllerWith([mover], grid: true)..drawing.gridSpacing = 25;
      c.setSelectedNodes({mover: {0, 1}});
      drag(c, DirectSelectTool(), const Offset(10, 10), const Offset(22, 27));
      expect(mover.nodes[0].anchorPoint, const Offset(25, 25));
      expect(mover.nodes[1].anchorPoint, const Offset(45, 25));
    });

    test('pen points snap', () {
      final c = controllerWith([square(100, 100)], edges: true);
      final pen = PenTool();
      c.tool = pen;
      for (final p in [const Offset(20, 20), const Offset(125, 96)]) {
        pen.begin(c, ToolEvent(p, 1));
        pen.end(c, ToolEvent(p, 1));
      }
      expect(c.activePath!.nodes.last.anchorPoint, const Offset(125, 100));
    });

    test('reach is in screen pixels, wider for fingers', () {
      expect(const ToolEvent(Offset.zero, 2).snapTolerance, 5);
      expect(const ToolEvent(Offset.zero, 1, touch: true).snapTolerance, 25);
    });
  });
}
