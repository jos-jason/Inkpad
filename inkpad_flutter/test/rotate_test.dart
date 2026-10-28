import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/tools/tool.dart';

Matcher near(Offset o) => predicate<Offset>((a) => (a - o).distance < 1e-6, 'near $o');

/// A 100 × 20 bar centered on (50, 50), selected.
(DrawingController, InkPath) setup() {
  final c = DrawingController();
  final bar = InkPath.rect(const Rect.fromLTWH(0, 40, 100, 20));
  c.addElement(bar);
  c.select(bar);
  return (c, bar);
}

void drag(DrawingController c, Offset from, Offset to, {bool shift = false}) {
  c.tool.begin(c, ToolEvent(from, 1));
  c.tool.move(c, ToolEvent(to, 1, shift: shift));
  c.tool.end(c, ToolEvent(to, 1, shift: shift));
}

void main() {
  test('geometry helpers', () {
    expect(sweptAngle(Offset.zero, const Offset(1, 0), const Offset(0, 1)), closeTo(math.pi / 2, 1e-9));
    // Crossing ±180° gives the short way round.
    expect(sweptAngle(Offset.zero, const Offset(-1, 0.1), const Offset(-1, -0.1)), closeTo(0.2, 0.01));
    expect(snapAngle(0.3, 15), closeTo(math.pi / 12, 1e-9));
  });

  test('rotate tool: drag rotates about the selection center', () {
    final (c, bar) = setup();
    c.tool = RotateTool();
    expect((c.tool as RotateTool).pivot(c), const Offset(50, 50));
    drag(c, const Offset(100, 50), const Offset(50, 100)); // a quarter turn clockwise
    expect(bar.bounds.width, closeTo(20, 1e-9));
    expect(bar.bounds.height, closeTo(100, 1e-9));
    expect(bar.bounds.center, near(const Offset(50, 50)));
    c.undo();
    expect(c.drawing.activeLayer.elements.single.bounds, const Rect.fromLTWH(0, 40, 100, 20));
  });

  test('rotate tool: a tap moves the pivot; Shift snaps to 15°', () {
    final (c, bar) = setup();
    final tool = RotateTool();
    c.tool = tool;
    c.tool.begin(c, const ToolEvent(Offset(0, 50), 1));
    c.tool.end(c, const ToolEvent(Offset(0, 50), 1));
    expect(tool.pivot(c), const Offset(0, 50));
    expect(c.canUndo, isFalse); // a tap changes nothing in the drawing

    // About 50° from the pivot, snapped to 45°.
    final to = Offset(100 * math.cos(0.87), 50 + 100 * math.sin(0.87));
    drag(c, const Offset(100, 50), to, shift: true);
    expect(bar.nodes[1].anchorPoint, near(Offset(100 * math.cos(math.pi / 4), 50 + 100 * math.sin(math.pi / 4)) - Offset(-10 * math.sin(math.pi / 4), 10 * math.cos(math.pi / 4))));
  });

  test('rotate tool: pivot resets when the selection changes', () {
    final (c, _) = setup();
    final tool = RotateTool();
    c.tool = tool;
    c.tool.begin(c, const ToolEvent(Offset(5, 5), 1));
    c.tool.end(c, const ToolEvent(Offset(5, 5), 1));
    final other = InkPath.rect(const Rect.fromLTWH(200, 200, 10, 10));
    c.addElement(other);
    c.select(other);
    expect(tool.pivot(c), const Offset(205, 205));
  });

  test('rotate 90° and flip commands, with undo', () {
    final (c, bar) = setup();
    c.rotateSelection(90);
    expect(bar.bounds.width, closeTo(20, 1e-9));
    c.rotateSelection(-90);
    expect(bar.bounds.width, closeTo(100, 1e-9));

    final tri = InkPath(nodes: [
      const BezierNode.anchor(Offset(0, 0)),
      const BezierNode.anchor(Offset(10, 0)),
      const BezierNode.anchor(Offset(0, 30)),
    ], closed: true);
    c.addElement(tri);
    c.select(tri);
    c.flipSelection(horizontal: true);
    expect(tri.nodes.map((n) => n.anchorPoint), [const Offset(10, 0), const Offset(0, 0), const Offset(10, 30)]);
    c.flipSelection(horizontal: false);
    expect(tri.nodes.last.anchorPoint, const Offset(10, 0));
    c.undo();
    c.undo();
    expect((c.drawing.activeLayer.elements.last as InkPath).nodes.last.anchorPoint, const Offset(0, 30));
  });

  test('flipped and rotated images still hit-test correctly', () {
    final png = Uint8List(37)
      ..setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
      ..setAll(12, 'IHDR'.codeUnits);
    ByteData.sublistView(png)
      ..setUint32(16, 100)
      ..setUint32(20, 20)
      ..setUint32(33, 424242);
    final c = DrawingController(drawing: InkDrawing(width: 100, height: 100));
    c.placeImage(png);
    final img = c.selection.single as InkImage;
    c.flipSelection(horizontal: true);
    expect(img.hitTest(const Offset(10, 50), 0), isTrue);
    c.rotateSelection(90);
    expect(img.hitTest(const Offset(50, 10), 0), isTrue);
    expect(img.hitTest(const Offset(10, 50), 0), isFalse);
  });
}
