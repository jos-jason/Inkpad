import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';

void main() {
  group('BezierNode', () {
    test('reflect mirrors the opposite handle', () {
      const n = BezierNode.anchor(Offset(10, 10));
      final m = n.moveControlHandle(HandleKind.outPoint, const Offset(20, 10), ReflectionMode.reflect);
      expect(m.inPoint, const Offset(0, 10));
      expect(m.isCorner, isFalse);
    });

    test('reflectIndependent keeps the opposite handle length', () {
      const n = BezierNode(Offset(5, 10), Offset(10, 10), Offset(30, 10));
      expect(n.reflectionMode, ReflectionMode.reflectIndependent);
      final m = n.moveControlHandle(HandleKind.inPoint, const Offset(10, 0), n.reflectionMode);
      expect(m.outPoint.dx, closeTo(10, 1e-9));
      expect(m.outPoint.dy, closeTo(30, 1e-9));
    });

    test('corner node is independent', () {
      const n = BezierNode(Offset(0, 0), Offset(10, 10), Offset(20, 0));
      expect(n.reflectionMode, ReflectionMode.independent);
      expect(n.isCorner, isTrue);
    });
  });

  group('Affine', () {
    test('then / inverted round-trip', () {
      final t = Affine.rotationAbout(const Offset(5, 5), 0.7).then(Affine.scale(2, 3));
      final p = t.inverted().apply(t.apply(const Offset(3, 4)));
      expect(p.dx, closeTo(3, 1e-9));
      expect(p.dy, closeTo(4, 1e-9));
    });
  });

  group('InkPath', () {
    test('rect SVG data', () {
      final p = InkPath.rect(const Rect.fromLTWH(0, 0, 10, 20));
      expect(p.svgPathData, 'M0 0L10 0L10 20L0 20L0 0Z');
    });

    test('oval bounds match rect', () {
      final p = InkPath.oval(const Rect.fromLTWH(10, 10, 100, 50));
      final b = p.bounds;
      expect(b.left, closeTo(10, 0.01));
      expect(b.right, closeTo(110, 0.01));
      expect(b.bottom, closeTo(60, 0.01));
    });

    test('insertAnchor keeps curve shape', () {
      final p = InkPath.oval(const Rect.fromLTWH(0, 0, 100, 100));
      final before = p.segments.first.pointAt(0.75);
      p.insertAnchor(0, 0.5);
      expect(p.nodes.length, 5);
      final after = p.segments.elementAt(1).pointAt(0.5);
      expect((before - after).distance, lessThan(1e-9));
    });

    test('hit testing', () {
      final p = InkPath.rect(const Rect.fromLTWH(0, 0, 10, 10))
        ..stroke = const StrokeStyle(width: 2);
      expect(p.hitTest(const Offset(5, 5), 1), isFalse); // no fill
      expect(p.hitTest(const Offset(5, 0.5), 1), isTrue); // on stroke
      p.fill = InkColor.black;
      expect(p.hitTest(const Offset(5, 5), 1), isTrue);
    });
  });

  group('InkDrawing', () {
    test('JSON round-trip', () {
      final d = InkDrawing();
      d.activeLayer.elements.add(InkGroup([
        InkPath.oval(const Rect.fromLTWH(0, 0, 10, 10))..fill = const InkColor(1, 0, 0, 0.5),
        InkPath.rect(const Rect.fromLTWH(5, 5, 10, 10))..stroke = const StrokeStyle(width: 3),
      ], opacity: 0.8));
      final copy = InkDrawing.decode(d.encode());
      expect(copy.encode(), d.encode());
      expect(copy.toSvg(), d.toSvg());
    });

    test('SVG export', () {
      final d = InkDrawing(width: 100, height: 50);
      d.activeLayer.elements.add(InkPath.rect(const Rect.fromLTWH(0, 0, 10, 10))..fill = InkColor.fromHex('#ff8000'));
      final svg = d.toSvg();
      expect(svg, contains('viewBox="0 0 100 50"'));
      expect(svg, contains('<g id="Layer 1">'));
      expect(svg, contains('fill="#ff8000"'));
    });
  });

  group('Tools', () {
    test('pen: two clicks then close by clicking the first node', () {
      final c = DrawingController()..tool = PenTool();
      void click(Offset p) {
        final e = ToolEvent(p, 1);
        c.tool.begin(c, e);
        c.tool.end(c, e);
      }

      click(const Offset(0, 0));
      click(const Offset(100, 0));
      click(const Offset(100, 100));
      click(const Offset(0, 0));
      final path = c.drawing.activeLayer.elements.single as InkPath;
      expect(path.closed, isTrue);
      expect(path.nodes.length, 3);
      expect(c.activePath, isNull);
    });

    test('pen: drag creates smooth node', () {
      final c = DrawingController()..tool = PenTool();
      c.tool.begin(c, const ToolEvent(Offset(0, 0), 1));
      c.tool.move(c, const ToolEvent(Offset(20, 0), 1));
      c.tool.end(c, const ToolEvent(Offset(20, 0), 1));
      final n = c.activePath!.nodes.single;
      expect(n.outPoint, const Offset(20, 0));
      expect(n.inPoint, const Offset(-20, 0));
    });

    test('shape tool + select/move + undo', () {
      final c = DrawingController()..tool = ShapeTool(ShapeKind.rectangle);
      c.tool.begin(c, const ToolEvent(Offset(10, 10), 1));
      c.tool.move(c, const ToolEvent(Offset(50, 50), 1));
      c.tool.end(c, const ToolEvent(Offset(50, 50), 1));
      final rect = c.drawing.activeLayer.elements.single;
      expect(rect.bounds, const Rect.fromLTRB(10, 10, 50, 50));

      c.tool = SelectionTool();
      c.tool.begin(c, const ToolEvent(Offset(30, 30), 1));
      c.tool.move(c, const ToolEvent(Offset(40, 30), 1));
      c.tool.end(c, const ToolEvent(Offset(40, 30), 1));
      expect(c.drawing.activeLayer.elements.single.bounds.left, 20);

      c.undo();
      expect(c.drawing.activeLayer.elements.single.bounds.left, 10);
      c.undo();
      expect(c.drawing.activeLayer.elements, isEmpty);
      c.redo();
      c.redo();
      expect(c.drawing.activeLayer.elements.single.bounds.left, 20);
    });

    test('anchor tool: click edge adds a point, click point removes it', () {
      final c = DrawingController();
      final rect = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 100))..stroke = const StrokeStyle();
      c.addElement(rect);
      c.tool = AnchorTool();

      // Middle of the top edge.
      c.tool.begin(c, const ToolEvent(Offset(50, 1), 1));
      expect(rect.nodes.length, 5);
      expect(rect.nodes[1].anchorPoint.dx, closeTo(50, 0.5));
      expect(rect.nodes[1].hasInPoint || rect.nodes[1].hasOutPoint, isFalse);
      expect(rect.svgPathData, isNot(contains('C')));
      expect(c.selection, {rect});

      // Click the new point again: removed.
      c.tool.begin(c, ToolEvent(rect.nodes[1].anchorPoint, 1));
      expect(rect.nodes.length, 4);

      c.undo();
      final restored = c.drawing.activeLayer.elements.single as InkPath;
      expect(restored.nodes.length, 5);
    });

    test('anchor tool: never removes below two points', () {
      final c = DrawingController();
      final line = InkPath(nodes: [const BezierNode.anchor(Offset(0, 0)), const BezierNode.anchor(Offset(100, 0))]);
      c.addElement(line);
      c.select(line);
      c.tool = AnchorTool();
      c.tool.begin(c, const ToolEvent(Offset(0, 0), 1));
      expect(line.nodes.length, 2);
      expect(c.canUndo, isFalse);
    });

    test('anchor tool: alt-click toggles corner and smooth', () {
      final c = DrawingController();
      final rect = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 100));
      c.addElement(rect);
      c.select(rect);
      c.tool = AnchorTool();
      c.tool.begin(c, const ToolEvent(Offset(100, 0), 1, alt: true));
      final n = rect.nodes[1];
      expect(n.hasInPoint && n.hasOutPoint, isTrue);
      expect(n.isCorner, isFalse);
      c.tool.begin(c, const ToolEvent(Offset(100, 0), 1, alt: true));
      expect(rect.nodes[1].hasInPoint || rect.nodes[1].hasOutPoint, isFalse);
    });
  });
}
