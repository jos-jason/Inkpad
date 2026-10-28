import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/geometry/pathfinder.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';

const red = InkColor(1, 0, 0), blue = InkColor(0, 0, 1);

InkPath line(Offset a, Offset b) => InkPath(nodes: [BezierNode.anchor(a), BezierNode.anchor(b)]);

void click(DrawingController c, Offset p, {bool shift = false, int count = 1}) {
  c.tool.begin(c, ToolEvent(p, 1, shift: shift, count: count));
  c.tool.end(c, ToolEvent(p, 1, shift: shift, count: count));
}

void drag(DrawingController c, Offset from, Offset to, {bool shift = false}) {
  c.tool.begin(c, ToolEvent(from, 1, shift: shift));
  c.tool.move(c, ToolEvent(to, 1, shift: shift));
  c.tool.end(c, ToolEvent(to, 1, shift: shift));
}

void main() {
  group('direct select', () {
    late DrawingController c;
    late InkPath a, b;
    setUp(() {
      c = DrawingController();
      a = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 100));
      b = InkPath.rect(const Rect.fromLTWH(200, 0, 100, 100));
      c.drawing.activeLayer.elements.addAll([a, b]);
      c.tool = DirectSelectTool();
    });

    test('click selects one point; shift adds points on other paths; drag moves them all', () {
      click(c, const Offset(100, 0));
      expect(c.selectedNodes, {a: {1}});
      expect(c.selection, {a}); // the owner, for the style panels
      click(c, const Offset(200, 0), shift: true);
      expect(c.selectedNodes, {a: {1}, b: {0}});
      drag(c, const Offset(100, 0), const Offset(110, 5));
      expect(a.nodes[1].anchorPoint, const Offset(110, 5));
      expect(b.nodes[0].anchorPoint, const Offset(210, 5));
      expect(a.nodes[0].anchorPoint, Offset.zero); // unselected points stay
      c.undo();
      expect((c.drawing.activeLayer.elements.first as InkPath).nodes[1].anchorPoint, const Offset(100, 0));
      expect(c.selectedNodes, isEmpty);
    });

    test('shift-click a selected point deselects it', () {
      click(c, const Offset(0, 0));
      click(c, const Offset(100, 0), shift: true);
      click(c, const Offset(0, 0), shift: true);
      expect(c.selectedNodes, {a: {1}});
    });

    test('marquee adds the points inside it; tapping empty space selects nothing', () {
      drag(c, const Offset(50, -10), const Offset(250, 50));
      expect(c.selectedNodes, {a: {1}, b: {0}});
      expect(c.selection, {a, b});
      click(c, const Offset(150, 300)); // empty: clears
      expect(c.selectedNodes, isEmpty);
      expect(c.selection, isEmpty);
    });

    test('handles of selected points, double-click, delete', () {
      click(c, const Offset(100, 0), count: 2); // add handles
      expect(a.nodes[1].hasOutPoint, isTrue);
      final out = a.nodes[1].outPoint;
      drag(c, out, out + const Offset(0, 20));
      expect(a.nodes[1].outPoint, out + const Offset(0, 20));
      expect(a.nodes[1].isCorner, isFalse); // the opposite handle followed

      click(c, const Offset(0, 0)); // adds a second point
      expect(c.selectedNodes, {a: {0, 1}});
      c.deleteSelection(); // Delete removes points, not the shape
      expect(a.nodes.length, 2);
      expect(c.drawing.activeLayer.elements.length, 2);
    });

    test('points inside groups and compound paths are editable', () {
      final inner = InkPath.rect(const Rect.fromLTWH(400, 0, 10, 10));
      final g = InkGroup([inner, InkPath.rect(const Rect.fromLTWH(500, 0, 10, 10))]);
      c.drawing.activeLayer.elements.add(g);
      click(c, const Offset(410, 10));
      expect(c.selectedNodes, {inner: {2}});
      expect(c.selection, {g});
    });

    test('deleting all but one point removes the path', () {
      final l = line(const Offset(0, 300), const Offset(50, 300));
      c.drawing.activeLayer.elements.add(l);
      click(c, const Offset(0, 300));
      c.deleteSelectedAnchors();
      expect(c.drawing.activeLayer.elements, isNot(contains(l)));
    });

    test('switching tools clears the point selection', () {
      click(c, const Offset(0, 0));
      c.tool = SelectionTool();
      expect(c.selectedNodes, isEmpty);
    });
  });

  group('Path menu', () {
    test('add anchor points to selected paths', () {
      final c = DrawingController();
      final p = InkPath.rect(const Rect.fromLTWH(0, 0, 10, 10));
      c.addElement(p);
      c.select(p);
      c.addAnchorPoints();
      expect(p.nodes.length, 8);
      expect(p.nodes[1].anchorPoint, const Offset(5, 0));
    });

    test('join two open paths: touching ends merge, gaps get a segment, loops close', () {
      final c = DrawingController();
      final top = line(const Offset(0, 0), const Offset(10, 0))..stroke = const StrokeStyle(color: red);
      final other = line(const Offset(20, 0), const Offset(10, 0));
      c.drawing.activeLayer.elements.addAll([other, top]);
      c.selection.addAll([top, other]);
      expect(c.canJoinPaths, isTrue);
      c.joinPaths();
      final joined = c.drawing.activeLayer.elements.single as InkPath;
      expect(joined.nodes.map((n) => n.anchorPoint), [Offset.zero, const Offset(10, 0), const Offset(20, 0)]);
      expect(joined.stroke!.color, red);

      final back = line(const Offset(20, 0), const Offset(0, 0));
      c.drawing.activeLayer.elements.add(back);
      c.selection
        ..clear()
        ..addAll([joined, back]);
      c.joinPaths();
      final loop = c.drawing.activeLayer.elements.single as InkPath;
      expect(loop.closed, isTrue);
      expect(loop.nodes.length, 3);

      final gap = DrawingController();
      final l1 = line(Offset.zero, const Offset(10, 0)), l2 = line(const Offset(30, 0), const Offset(40, 0));
      gap.drawing.activeLayer.elements.addAll([l1, l2]);
      gap.selection.addAll([l1, l2]);
      gap.joinPaths();
      expect((gap.drawing.activeLayer.elements.single as InkPath).nodes.length, 4);
    });

    test('combine and separate paths', () {
      final c = DrawingController();
      final outer = InkPath.rect(const Rect.fromLTWH(0, 0, 30, 30))..fill = red;
      final inner = InkPath.rect(const Rect.fromLTWH(10, 10, 10, 10))..fill = blue..fillRule = FillRule.evenOdd;
      c.drawing.activeLayer.elements.addAll([outer, inner]);
      c.selection.addAll([outer, inner]);
      c.combinePaths();
      final compound = c.drawing.activeLayer.elements.single as InkCompoundPath;
      expect(compound.subpaths.length, 2);
      expect(compound.fill, blue); // topmost's style
      expect(compound.toFlutterPath().contains(const Offset(15, 15)), isFalse); // a hole
      c.separatePaths();
      expect(c.drawing.activeLayer.elements.length, 2);
      expect(c.selection.length, 2);
      expect(c.drawing.activeLayer.elements.every((e) => (e as InkPath).fill == blue), isTrue);
    });

    test('separating keeps a gradient in place and releases a mask\'s contents', () {
      final c = DrawingController();
      final compound = InkCompoundPath([
        InkPath.rect(const Rect.fromLTWH(0, 0, 40, 40)),
        InkPath.rect(const Rect.fromLTWH(60, 0, 40, 40)),
      ], fill: InkGradient.between(red, blue));
      final inside = InkPath.rect(const Rect.fromLTWH(10, 10, 80, 20))..fill = red;
      compound.maskedElements = [inside];
      c.addElement(compound);
      c.select(compound);
      expect(c.canSeparatePaths, isTrue);
      c.separatePaths();
      final els = c.drawing.activeLayer.elements;
      expect(els.length, 3);
      expect(els.last, same(inside)); // the contents, back on the layer, on top
      final right = els[1] as InkPath;
      expect(right.isMasking, isFalse);
      // Still one gradient across both pieces: the right piece is mostly blue.
      final g = (right.fill as InkGradient).fitted(right.bounds);
      expect(g.documentStart.dx, 0);
      expect(g.documentEnd.dx, 100);
      expect(c.selection, els.take(2).toSet());
      c.undo();
      expect((c.drawing.activeLayer.elements.single as InkCompoundPath).isMasking, isTrue);
    });

    test('outline stroke: replaces stroke-only shapes; keeps the fill underneath', () {
      final c = DrawingController();
      final stroked = line(Offset.zero, const Offset(100, 0))..stroke = const StrokeStyle(width: 10, color: red, cap: LineCap.butt);
      final filled = InkPath.rect(const Rect.fromLTWH(0, 50, 40, 40))
        ..fill = blue
        ..stroke = const StrokeStyle(width: 4, color: red);
      c.drawing.activeLayer.elements.addAll([stroked, filled]);
      c.selection.addAll([stroked, filled]);
      c.outlineStroke();
      final els = c.drawing.activeLayer.elements;
      expect(els.length, 3);
      expect((els[0] as InkStylable).fill, red);
      expect((els[0] as InkStylable).stroke, isNull);
      expect(els[1], same(filled));
      expect(filled.stroke, isNull);
      expect((els[2] as InkStylable).fill, red);
      expect(c.selection.length, 2);
    });

    test('shape operations: style from top (or bottom for subtract), undoable', () {
      final c = DrawingController();
      final a = InkPath.rect(const Rect.fromLTWH(0, 0, 20, 20))..fill = red;
      final b = InkPath.rect(const Rect.fromLTWH(10, 10, 20, 20))..fill = blue;
      c.drawing.activeLayer.elements.addAll([a, b]);
      c.selection.addAll([a, b]);
      c.combineShapes(BooleanOp.unite);
      final u = c.drawing.activeLayer.elements.single as InkStylable;
      expect(u.fill, blue);
      expect(u.bounds, const Rect.fromLTWH(0, 0, 30, 30));
      c.undo();
      expect(c.drawing.activeLayer.elements.length, 2);

      final els = c.drawing.activeLayer.elements;
      c.selection.addAll(els);
      c.combineShapes(BooleanOp.subtractFront);
      final s = c.drawing.activeLayer.elements.single as InkStylable;
      expect(s.fill, red);
      expect(s.toFlutterPath().contains(const Offset(15, 15)), isFalse);
      expect(s.toFlutterPath().contains(const Offset(5, 5)), isTrue);
    });

    test('masks cannot be combined', () {
      final c = DrawingController();
      final m = InkPath.rect(const Rect.fromLTWH(0, 0, 10, 10))..maskedElements = [InkPath.rect(const Rect.fromLTWH(0, 0, 5, 5))];
      final o = InkPath.rect(const Rect.fromLTWH(0, 0, 10, 10));
      c.drawing.activeLayer.elements.addAll([m, o]);
      c.selection.addAll([m, o]);
      expect(c.canCombineShapes, isFalse);
      expect(c.canCombinePaths, isFalse);
    });
  });
}
