import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';

const red = InkColor(1, 0, 0), blue = InkColor(0, 0, 1);

void stroke(DrawingController c, List<Offset> pts, {int count = 1}) {
  c.tool.begin(c, ToolEvent(pts.first, 1, count: count));
  for (final p in pts.skip(1)) {
    c.tool.move(c, ToolEvent(p, 1));
  }
  c.tool.end(c, ToolEvent(pts.last, 1));
}

/// A wobbly hand-drawn circle.
List<Offset> scribbleCircle(Offset c, double r, {int n = 120}) => [
      for (var i = 0; i <= n; i++)
        c + Offset(math.cos(i / n * 2 * math.pi), math.sin(i / n * 2 * math.pi)) * (r + math.sin(i * 1.7) * 0.6),
    ];

void main() {
  test('freehand: a scribbled loop becomes a smooth closed shape in the current style', () {
    final c = DrawingController()..fillPaint = red;
    c.tool = FreehandTool(closeShape: true);
    stroke(c, scribbleCircle(const Offset(100, 100), 50));
    final p = c.drawing.activeLayer.elements.single as InkPath;
    expect(p.closed, isTrue);
    expect(p.fill, red);
    expect(p.nodes.length, lessThan(12));
    expect(p.bounds.center.dx, closeTo(100, 3));
    expect(c.selection, {p});
    c.undo();
    expect(c.drawing.activeLayer.elements, isEmpty);
  });

  test('brush: an open line in the current stroke, no fill', () {
    final c = DrawingController()
      ..fillPaint = red
      ..strokeStyle = const StrokeStyle(width: 5, color: blue);
    c.tool = FreehandTool(closeShape: false);
    stroke(c, [for (var x = 0.0; x <= 200; x += 4) Offset(x, 50 + math.sin(x / 30) * 20)]);
    final p = c.drawing.activeLayer.elements.single as InkPath;
    expect(p.closed, isFalse);
    expect(p.fill, isNull);
    expect(p.stroke!.color, blue);
    expect(p.nodes.first.anchorPoint, const Offset(0, 50));

    c.strokeStyle = null; // no stroke set: draw in the fill color
    stroke(c, [const Offset(0, 0), const Offset(50, 10), const Offset(100, 0)]);
    expect((c.drawing.activeLayer.elements.last as InkPath).stroke!.color, red);
  });

  group('eraser', () {
    test('cuts a channel through a closed shape and splits an open line', () {
      final c = DrawingController();
      final square = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 100))..fill = red;
      final line = InkPath(nodes: [const BezierNode.anchor(Offset(0, 200)), const BezierNode.anchor(Offset(100, 200))])
        ..stroke = const StrokeStyle(color: blue);
      c.drawing.activeLayer.elements.addAll([square, line]);
      c.tool = EraserTool()..size = 10;
      stroke(c, [for (var y = -20.0; y <= 220; y += 5) Offset(50, y)]);

      final els = c.drawing.activeLayer.elements;
      final cut = els.first as InkStylable;
      expect(cut.fill, red);
      expect(cut.toFlutterPath().contains(const Offset(50, 50)), isFalse); // erased
      expect(cut.toFlutterPath().contains(const Offset(20, 50)), isTrue);
      final pieces = els.skip(1).cast<InkPath>().toList();
      expect(pieces.length, 2); // the line is now two lines
      expect(pieces.every((p) => p.stroke!.color == blue && !p.closed), isTrue);
      expect(pieces.map((p) => p.bounds.width).every((w) => w < 50), isTrue);
    });

    test('a tap erases a dot; with a selection only selected shapes are erased', () {
      final c = DrawingController();
      final a = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 100))..fill = red;
      final b = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 100))..fill = blue;
      c.drawing.activeLayer.elements.addAll([a, b]);
      c.selection.add(b);
      c.tool = EraserTool()..size = 20;
      stroke(c, [const Offset(50, 50)]);
      expect(c.drawing.activeLayer.elements.first, same(a)); // untouched
      final erased = c.drawing.activeLayer.elements.last as InkStylable;
      expect(erased.toFlutterPath().contains(const Offset(50, 50)), isFalse);
      expect(erased.toFlutterPath().contains(const Offset(50, 35)), isTrue);
    });

    test('erasing a shape entirely removes it', () {
      final c = DrawingController();
      c.drawing.activeLayer.elements.add(InkPath.rect(const Rect.fromLTWH(0, 0, 4, 4))..fill = red);
      c.tool = EraserTool()..size = 40;
      stroke(c, [const Offset(2, 2)]);
      expect(c.drawing.activeLayer.elements, isEmpty);
    });
  });

  group('scissors', () {
    test('cut an open path in the middle of a segment, or at a middle point', () {
      final c = DrawingController();
      final p = InkPath(nodes: [
        const BezierNode.anchor(Offset(0, 0)),
        const BezierNode.anchor(Offset(100, 0)),
        const BezierNode.anchor(Offset(200, 0)),
      ])
        ..stroke = const StrokeStyle(color: red);
      c.drawing.activeLayer.elements.add(p);
      c.tool = ScissorsTool();
      stroke(c, [const Offset(50, 1)]);
      final els = c.drawing.activeLayer.elements.cast<InkPath>();
      expect(els.length, 2);
      expect(els.first.nodes.last.anchorPoint.dx, closeTo(50, 0.5));
      expect(els.last.nodes.first.anchorPoint.dx, closeTo(50, 0.5));
      expect(els.last.stroke!.color, red);
      expect(c.selection, {els.last});

      stroke(c, [const Offset(100, 0)]); // a middle point of the second piece
      expect(c.drawing.activeLayer.elements.length, 3);
      stroke(c, [const Offset(200, 0)]); // an end: nothing to cut
      expect(c.drawing.activeLayer.elements.length, 3);
    });

    test('cutting a closed shape opens it at that point', () {
      final c = DrawingController();
      final r = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 100));
      c.drawing.activeLayer.elements.add(r);
      c.tool = ScissorsTool();
      stroke(c, [const Offset(100, 0)]);
      expect(r.closed, isFalse);
      expect(r.nodes.length, 5);
      expect(r.nodes.first.anchorPoint, r.nodes.last.anchorPoint);
      expect(r.nodes.first.anchorPoint, const Offset(100, 0));
    });

    test('subpaths of compound paths can be cut', () {
      final c = DrawingController();
      final inner = InkPath(nodes: [const BezierNode.anchor(Offset(0, 0)), const BezierNode.anchor(Offset(100, 0))]);
      final compound = InkCompoundPath([inner, InkPath.rect(const Rect.fromLTWH(0, 50, 10, 10))]);
      c.drawing.activeLayer.elements.add(compound);
      c.tool = ScissorsTool();
      stroke(c, [const Offset(50, 0)]);
      expect(compound.subpaths.length, 3);
      expect(c.selection, {compound});
    });
  });

  test('eyedropper copies a style onto the selection and the current style', () {
    final c = DrawingController();
    final source = InkPath.rect(const Rect.fromLTWH(0, 0, 50, 50))
      ..fill = red
      ..stroke = const StrokeStyle(width: 7, color: blue)
      ..opacity = 0.5;
    final target = InkPath.rect(const Rect.fromLTWH(100, 0, 50, 50))..fill = blue;
    c.drawing.activeLayer.elements.addAll([source, target]);
    c.selection.add(target);
    c.tool = EyedropperTool();
    stroke(c, [const Offset(25, 25)]);
    expect(target.fill, red);
    expect(target.stroke!.width, 7);
    expect(target.opacity, 0.5);
    expect(c.fillPaint, red);
    expect(c.strokeStyle!.width, 7);
    c.undo();
    expect((c.drawing.activeLayer.elements.last as InkPath).fill, blue);
  });

  test('spiral: winds in from the drag point, open, unfilled', () {
    final c = DrawingController()..fillPaint = red;
    c.tool = ShapeTool(ShapeKind.spiral);
    stroke(c, [const Offset(100, 100), const Offset(200, 100)]);
    final s = c.drawing.activeLayer.elements.single as InkPath;
    expect(s.closed, isFalse);
    expect(s.fill, isNull);
    expect(s.nodes.length, 21);
    expect((s.nodes.last.anchorPoint - const Offset(200, 100)).distance, lessThan(1e-6));
    expect((s.nodes.first.anchorPoint - const Offset(100, 100)).distance, lessThan(5)); // near the center
  });
}
