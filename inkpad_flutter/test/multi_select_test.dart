import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';

ToolEvent finger(Offset p) => ToolEvent(p, 1, touch: true);

void tap(DrawingController c, Offset p) {
  c.tool.begin(c, finger(p));
  c.tool.end(c, finger(p));
}

void drag(DrawingController c, Offset from, Offset to) {
  c.tool.begin(c, finger(from));
  c.tool.move(c, finger(to));
  c.tool.end(c, finger(to));
}

void main() {
  late DrawingController c;
  late InkPath a, b, small;
  setUp(() {
    c = DrawingController();
    InkPath box(Rect r) => InkPath.rect(r)..fill = const InkColor(0, 0, 1);
    a = box(const Rect.fromLTWH(0, 0, 200, 200));
    b = box(const Rect.fromLTWH(300, 0, 200, 200));
    small = box(const Rect.fromLTWH(600, 0, 40, 40));
    c.drawing.activeLayer.elements.addAll([a, b, small]);
    c.tool = DirectSelectTool();
  });

  test('tap objects to add them; tap one again to take it away', () {
    tap(c, const Offset(100, 100));
    expect(c.selection, {a});
    tap(c, const Offset(400, 100));
    expect(c.selection, {a, b});
    tap(c, const Offset(100, 100));
    expect(c.selection, {b});
  });

  test('dragging any selected object moves them all', () {
    tap(c, const Offset(100, 100));
    tap(c, const Offset(400, 100));
    drag(c, const Offset(400, 100), const Offset(430, 140));
    expect(a.bounds.topLeft, const Offset(30, 40));
    expect(b.bounds.topLeft, const Offset(330, 40));
    expect(c.selection, {a, b}); // a drag doesn't take anything away
    expect(small.bounds.topLeft, const Offset(600, 0));
  });

  test('a tap in the middle of a small object picks the object, not a corner', () {
    tap(c, const Offset(620, 20)); // 28 points from each corner
    expect(c.selection, {small});
    expect(c.selectedNodes, isEmpty);
  });

  test('tap points to add them, tap one again to take it away; drag one to move them all', () {
    tap(c, const Offset(100, 100)); // the object; its points show
    tap(c, const Offset(185, 12)); // near its top-right corner: within a fingertip
    expect(c.selectedNodes, {a: {1}});
    tap(c, const Offset(190, 195)); // bottom-right: added, the first kept
    expect(c.selectedNodes, {a: {1, 2}});
    tap(c, const Offset(10, 190)); // bottom-left
    expect(c.selectedNodes, {a: {1, 2, 3}});
    tap(c, const Offset(190, 195)); // again: taken away
    expect(c.selectedNodes, {a: {1, 3}});
    drag(c, const Offset(196, 4), const Offset(216, 24)); // a selected point
    expect(a.nodes[1].anchorPoint, const Offset(220, 20));
    expect(a.nodes[3].anchorPoint, const Offset(20, 220));
    expect(a.nodes[0].anchorPoint, Offset.zero); // unselected points stay
    expect(a.nodes[2].anchorPoint, const Offset(200, 200));
    expect(c.selectedNodes, {a: {1, 3}});
  });

  test('points of two objects can be selected together', () {
    tap(c, const Offset(100, 100));
    tap(c, const Offset(400, 100));
    tap(c, const Offset(198, 2));
    tap(c, const Offset(302, 2));
    expect(c.selectedNodes, {a: {1}, b: {0}});
    // With both objects selected, dragging a point moves both objects whole.
    drag(c, const Offset(198, 2), const Offset(208, 12));
    expect(a.bounds.topLeft, const Offset(10, 10));
    expect(a.bounds.size, const Size(200, 200)); // not reshaped
    expect(b.bounds.topLeft, const Offset(310, 10));
    tap(c, const Offset(410, 110)); // taking b away drops its points
    expect(c.selectedNodes, {a: {1}});
    expect(c.selection, {a});
    // With one object, dragging its selected point moves just that point.
    drag(c, const Offset(210, 10), const Offset(230, 10));
    expect(a.nodes[1].anchorPoint, const Offset(230, 10));
    expect(a.nodes[0].anchorPoint, const Offset(10, 10));
  });

  test('double-tap a handle to remove just that half', () {
    final curve = InkPath(nodes: [
      const BezierNode.anchor(Offset(0, 400)),
      const BezierNode(Offset(60, 400), Offset(100, 400), Offset(140, 400)),
      const BezierNode.anchor(Offset(200, 400)),
    ])
      ..stroke = const StrokeStyle(width: 2);
    c.drawing.activeLayer.elements.add(curve);
    tap(c, const Offset(150, 400)); // the curve
    tap(c, const Offset(102, 402)); // its middle point: handles show
    expect(c.selectedNodes[curve], {1});
    c.tool.begin(c, ToolEvent(const Offset(138, 402), 1, touch: true, count: 2));
    c.tool.end(c, ToolEvent(const Offset(138, 402), 1, touch: true, count: 2));
    final n = curve.nodes[1];
    expect(n.hasOutPoint, isFalse);
    expect(n.inPoint, const Offset(60, 400)); // the other half stays
    c.undo();
    expect((c.drawing.activeLayer.elements.last as InkPath).nodes[1].outPoint, const Offset(140, 400));
  });
}
