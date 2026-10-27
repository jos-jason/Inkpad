import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';

InkPath box(double x, double y, [double w = 10, double h = 10]) => InkPath.rect(Rect.fromLTWH(x, y, w, h));

(DrawingController, List<InkPath>) setup() {
  final c = DrawingController(drawing: InkDrawing(width: 200, height: 100));
  final shapes = [box(0, 0), box(50, 20, 20, 20), box(150, 60, 30, 10)];
  c.drawing.activeLayer.elements.addAll(shapes);
  return (c, shapes);
}

void main() {
  test('HSB round-trips', () {
    for (final c in const [InkColor(1, 0.5, 0), InkColor(0.2, 0.4, 0.9, 0.5), InkColor(0.5, 0.5, 0.5)]) {
      final back = InkColor.hsb(c.hue, c.saturation, c.brightness, c.alpha);
      expect(back.hexValue, c.hexValue);
      expect(back.alpha, c.alpha);
    }
    expect(InkColor.hsb(120, 1, 1).hexValue, '#00ff00');
  });

  test('select all spans layers; select all in layer does not', () {
    final (c, _) = setup();
    c.addLayer();
    c.drawing.activeLayer.elements.add(box(5, 5));
    c.selectAll();
    expect(c.selection.length, 4);
    c.selectAllInLayer();
    expect(c.selection.length, 1);
  });

  test('cut, copy, paste in place; duplicate in place', () async {
    final (c, s) = setup();
    c.selection.addAll([s[0], s[1]]);
    c.copySelection();
    await c.paste();
    expect(c.drawing.activeLayer.elements.length, 5);
    expect(c.selection.map((e) => e.bounds), [s[0].bounds, s[1].bounds]);
    c.cutSelection();
    expect(c.drawing.activeLayer.elements.length, 3);
    await c.paste();
    expect(c.drawing.activeLayer.elements.length, 5);
    c.selection
      ..clear()
      ..add(s[2]);
    c.duplicateInPlace();
    expect(c.selection.single.bounds, s[2].bounds);
    expect(c.selection.single, isNot(same(s[2])));
  });

  test('bring forward / send backward move one step past unselected neighbours', () {
    final (c, s) = setup();
    final els = c.drawing.activeLayer.elements;
    c.selection.add(s[0]);
    c.bringForward();
    expect(els, [s[1], s[0], s[2]]);
    c.bringForward();
    expect(els, [s[1], s[2], s[0]]);
    c.bringForward(); // already on top
    expect(els, [s[1], s[2], s[0]]);
    c.sendBackward();
    expect(els, [s[1], s[0], s[2]]);
  });

  test('align to the selection, or a single element to the page', () {
    final (c, s) = setup();
    c.selection.addAll(s);
    c.align(AlignEdge.right);
    expect(s.map((e) => e.bounds.right), [180, 180, 180]);
    c.align(AlignEdge.top);
    expect(s.map((e) => e.bounds.top), [0, 0, 0]);
    c.align(AlignEdge.middle);
    expect(s.map((e) => e.bounds.center.dy), everyElement(closeTo(10, 1e-9)));
    c.selection
      ..clear()
      ..add(s[0]);
    c.align(AlignEdge.center);
    expect(s[0].bounds.center.dx, 100); // page center
  });

  test('distribute spaces centers evenly', () {
    final (c, s) = setup();
    c.selection.addAll(s);
    c.distribute(horizontal: true);
    final xs = s.map((e) => e.bounds.center.dx).toList();
    expect(xs[1] - xs[0], closeTo(xs[2] - xs[1], 1e-9));
    expect(xs.first, 5); // ends stay put
    expect(xs.last, 165);
  });

  test('transform again repeats the last move, scale or rotation', () {
    final (c, s) = setup();
    final b = s[1]..fill = InkColor.black; // 50,20 20×20: drag from its middle
    c.selection.add(b);
    c.tool = SelectionTool();
    c.tool.begin(c, const ToolEvent(Offset(60, 30), 1));
    c.tool.move(c, const ToolEvent(Offset(80, 30), 1));
    c.tool.end(c, const ToolEvent(Offset(80, 30), 1));
    expect(b.bounds.left, 70);
    c.transformAgain();
    expect(b.bounds.left, 90);
    c.duplicateAndTransformAgain();
    expect(c.drawing.activeLayer.elements.length, 4);
    expect(c.selection.single.bounds.left, 110);
    expect(b.bounds.left, 90);
  });

  test('scale tool scales about the pivot, proportionally unless Shift', () {
    final (c, s) = setup();
    c.selection.add(s[1]); // 50,20 20x20, center (60,30)
    c.tool = ScaleTool();
    c.tool.begin(c, const ToolEvent(Offset(70, 30), 1));
    c.tool.move(c, const ToolEvent(Offset(80, 30), 1)); // twice as far from the center
    c.tool.end(c, const ToolEvent(Offset(80, 30), 1));
    expect(s[1].bounds, const Rect.fromLTWH(40, 10, 40, 40));
    c.tool.begin(c, const ToolEvent(Offset(80, 30), 1));
    c.tool.move(c, const ToolEvent(Offset(100, 30), 1, shift: true));
    expect(s[1].bounds.width, closeTo(80, 1e-9));
    expect(s[1].bounds.height, closeTo(40, 1e-9));
  });

  test('opacity applies to the selection and new shapes', () {
    final (c, s) = setup();
    c.selection.add(s[0]);
    c.setOpacity(0.4);
    expect(s[0].opacity, 0.4);
    expect(c.styledPath(InkPath()).opacity, 0.4);
    c.undo();
    expect(c.drawing.activeLayer.elements.first.opacity, 1);
  });

  test('layers: duplicate, move, opacity, highlight colors survive saving', () {
    final (c, _) = setup();
    c.duplicateActiveLayer();
    expect(c.drawing.layers.map((l) => l.name), ['Layer 1', 'Layer 1 copy']);
    expect(c.drawing.activeLayer.elements.length, 3);
    c.addLayer();
    expect(c.drawing.activeLayer.highlightColor, isNot(InkLayer.defaultHighlight));
    c.moveLayer(2, 0);
    expect(c.drawing.layers.first, same(c.drawing.activeLayer)); // active follows the move
    c.setLayerOpacity(0.5);
    c.drawing.units = 'cm';
    c.drawing.showRulers = false;
    final copy = InkDrawing.decode(c.drawing.encode());
    expect(copy.layers.first.opacity, 0.5);
    expect(copy.layers.first.highlightColor, c.drawing.layers.first.highlightColor);
    expect(copy.units, 'cm');
    expect(copy.showRulers, isFalse);
  });

  test('rounded rectangles and shape tool options', () {
    final r = InkPath.roundedRect(const Rect.fromLTWH(0, 0, 100, 50), 10);
    expect(r.nodes.length, 8);
    expect(r.bounds.width, closeTo(100, 1e-6));
    expect(InkPath.roundedRect(const Rect.fromLTWH(0, 0, 10, 10), 0).nodes.length, 4);

    final c = DrawingController();
    final star = ShapeTool(ShapeKind.star)
      ..starPoints = 7
      ..starInnerRatio = 0.3;
    c.tool = star;
    c.tool.begin(c, const ToolEvent(Offset(0, 0), 1));
    c.tool.move(c, const ToolEvent(Offset(100, 100), 1));
    c.tool.end(c, const ToolEvent(Offset(100, 100), 1));
    expect((c.drawing.activeLayer.elements.single as InkPath).nodes.length, 14);
  });

  test('reverse path direction', () {
    final (c, s) = setup();
    final first = s[0].nodes.first.anchorPoint;
    c.selection.add(s[0]);
    c.reversePaths();
    expect(s[0].nodes.last.anchorPoint, first);
    expect(Affine.identity.isIdentity, isTrue);
  });
}
