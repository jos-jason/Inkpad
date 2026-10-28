import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';
import 'package:inkpad/ui/drawing_canvas.dart';

/// A curve: a corner at (100,100), a smooth point at (200,100) with handles
/// 40 to each side, and a corner at (300,100).
InkPath curve() => InkPath(nodes: [
      const BezierNode.anchor(Offset(100, 100)),
      const BezierNode(Offset(160, 100), Offset(200, 100), Offset(240, 100)),
      const BezierNode.anchor(Offset(300, 100)),
    ])
  ..stroke = const StrokeStyle(width: 2);

ToolEvent finger(Offset p, {int count = 1, bool secondary = false}) => ToolEvent(p, 1, touch: true, count: count, secondary: secondary);

void tap(DrawingController c, Tool t, ToolEvent e) {
  t.begin(c, e);
  t.end(c, e);
}

void main() {
  test('reach: a fingertip like Inkpad (25), less for a Pencil and a mouse', () {
    expect(const ToolEvent(Offset.zero, 1, touch: true).slop(), 25);
    expect(const ToolEvent(Offset.zero, 1, pencil: true).slop(), 12);
    expect(const ToolEvent(Offset.zero, 1).slop(), 8);
    expect(const ToolEvent(Offset.zero, 2, touch: true).slop(), 12.5); // zoomed in: less of the drawing
  });

  group('select tool on a touchscreen', () {
    late DrawingController c;
    late InkPath p;
    late SelectionTool t;
    setUp(() {
      c = DrawingController(drawing: InkDrawing(width: 600, height: 400));
      p = curve();
      c.addElement(p);
      c.select(p);
      t = SelectionTool();
      c.tool = t;
    });

    test('a finger 20 points off still grabs a point; the nearest point wins', () {
      // Between the first and second points, nearer the second.
      tap(c, t, finger(const Offset(185, 112)));
      expect(c.selectedNodes[p], {1});
    });

    test('only the selected point shows (and gives up) its whiskers', () {
      // The second point's out handle at (240,100): not selected yet, so
      // touching near it grabs the point instead.
      t.begin(c, finger(const Offset(236, 104)));
      t.move(c, finger(const Offset(236, 154)));
      t.end(c, finger(const Offset(236, 154)));
      expect(p.nodes[1].anchorPoint, const Offset(200, 150));
      c.undo();
      p = c.drawing.allElements.single as InkPath;
      c.select(p);
      c.setSelectedNodes({p: {1}});
      // Now its handle is the nearest thing: dragging it bends the curve.
      t.begin(c, finger(const Offset(238, 102)));
      t.move(c, finger(const Offset(238, 152)));
      t.end(c, finger(const Offset(238, 152)));
      expect(p.nodes[1].anchorPoint, const Offset(200, 100));
      expect(p.nodes[1].outPoint, const Offset(240, 150));
      // A smooth point's other handle follows, unless a second finger is down.
      expect(p.nodes[1].inPoint.dy, lessThan(100));
      final inStart = p.nodes[1].inPoint;
      final grab = inStart + const Offset(3, -2); // a little off-center
      t.begin(c, finger(grab));
      t.move(c, finger(grab + const Offset(0, -38), secondary: true));
      t.end(c, finger(grab + const Offset(0, -38), secondary: true));
      expect(p.nodes[1].inPoint, inStart + const Offset(0, -38)); // moved by the drag, no jump
      expect(p.nodes[1].outPoint, const Offset(240, 150)); // left alone
    });

    test('double-tap a handle of the selected point to remove just that half', () {
      c.setSelectedNodes({p: {1}});
      tap(c, t, finger(const Offset(158, 103), count: 2)); // near the in handle (160,100)
      expect(p.nodes[1].hasInPoint, isFalse);
      expect(p.nodes[1].outPoint, const Offset(240, 100));
    });

    test('no scale handles: dragging just outside a corner moves the corner point', () {
      final r = InkPath.rect(const Rect.fromLTWH(100, 200, 100, 100));
      c.addElement(r);
      c.select(r);
      // Where a scale handle used to be, 14 points out from the corner.
      t.begin(c, finger(const Offset(90, 190)));
      t.move(c, finger(const Offset(70, 170)));
      t.end(c, finger(const Offset(70, 170)));
      expect(r.nodes.first.anchorPoint, const Offset(80, 180));
      expect(r.nodes[2].anchorPoint, const Offset(200, 300)); // not scaled
    });

    test('a second finger while moving keeps the move to 45°', () {
      tap(c, t, finger(const Offset(250, 300))); // empty: deselect
      c.select(p);
      t.begin(c, finger(const Offset(150, 100)));
      t.move(c, finger(const Offset(190, 112), secondary: true));
      t.end(c, finger(const Offset(190, 112), secondary: true));
      expect(p.nodes.first.anchorPoint.dy, 100); // straight across
    });
  });

  group('the canvas with fingers', () {
    late DrawingController c;
    late InkPath p;
    final key = GlobalKey<DrawingCanvasState>();

    Future<void> pump(WidgetTester tester) async {
      c = DrawingController(drawing: InkDrawing(width: 600, height: 400));
      p = InkPath.rect(const Rect.fromLTWH(100, 100, 200, 100))..fill = const InkColor(0, 0, 1);
      c.addElement(p);
      c.tool = SelectionTool();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DrawingCanvas(key: key, controller: c))));
      await tester.pump();
    }

    Offset screen(Offset doc) => key.currentState!.toScreen(doc) + const Offset(0, 0);

    testWidgets('two fingers together zoom without selecting or moving anything', (tester) async {
      await pump(tester);
      final scale = key.currentState!.scale;
      final a = await tester.startGesture(screen(const Offset(200, 150)), kind: PointerDeviceKind.touch);
      await tester.pump();
      final b = await tester.startGesture(screen(const Offset(400, 300)), kind: PointerDeviceKind.touch);
      await a.moveBy(const Offset(-40, -40));
      await b.moveBy(const Offset(40, 40));
      await a.up();
      await b.up();
      await tester.pump();
      expect(c.selection, isEmpty);
      expect(p.bounds, const Rect.fromLTWH(100, 100, 200, 100));
      expect(c.canUndo, isFalse);
      expect(key.currentState!.scale, greaterThan(scale));
    });

    testWidgets('a tap selects; a drag moves; a second finger during the drag constrains', (tester) async {
      await pump(tester);
      await tester.tapAt(screen(const Offset(200, 150)), kind: PointerDeviceKind.touch);
      await tester.pump();
      expect(c.selection, {p});
      final s = key.currentState!.scale;
      final a = await tester.startGesture(screen(const Offset(200, 150)), kind: PointerDeviceKind.touch);
      await a.moveBy(const Offset(10, 0));
      final b = await tester.startGesture(screen(const Offset(500, 380)), kind: PointerDeviceKind.touch);
      await a.moveBy(Offset(40 * s, 6 * s));
      await a.up();
      await b.up();
      await tester.pump();
      expect(p.bounds.top, closeTo(100, 1e-9)); // kept level
      expect(p.bounds.left, greaterThan(100));
      expect(key.currentState!.scale, s); // no zoom
    });
  });
}
