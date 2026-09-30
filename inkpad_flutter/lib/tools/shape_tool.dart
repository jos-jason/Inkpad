import 'dart:math' as math;
import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'tool.dart';

enum ShapeKind { rectangle, oval, star, polygon, line }

/// Drag out a shape. Ported from WDShapeTool.
/// Shift constrains proportions (or 45° for lines); Alt draws from the center.
class ShapeTool extends Tool {
  final ShapeKind kind;

  ShapeTool(this.kind);

  @override
  String get name => switch (kind) {
        ShapeKind.rectangle => 'Rectangle',
        ShapeKind.oval => 'Oval',
        ShapeKind.star => 'Star',
        ShapeKind.polygon => 'Polygon',
        ShapeKind.line => 'Line',
      };

  Offset _start = Offset.zero;
  InkPath? _shape;

  @override
  void begin(DrawingController c, ToolEvent e) {
    _start = e.point;
    _shape = null;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    final built = _build(c, e);
    if (_shape == null) {
      c.checkpoint();
      _shape = c.styledPath(built);
      if (kind == ShapeKind.line) _shape!.fill = null;
      c.addElement(_shape!);
      c.select(_shape!);
    } else {
      _shape!
        ..nodes = built.nodes
        ..closed = built.closed;
    }
    c.changed();
  }

  InkPath _build(DrawingController c, ToolEvent e) {
    var end = e.point;

    if (kind == ShapeKind.line) {
      if (e.shift) {
        final d = end - _start;
        final angle = (math.atan2(d.dy, d.dx) / (math.pi / 4)).round() * (math.pi / 4);
        end = _start + Offset(math.cos(angle), math.sin(angle)) * d.distance;
      }
      return InkPath(nodes: [BezierNode.anchor(_start), BezierNode.anchor(end)]);
    }

    var d = end - _start;
    if (e.shift) {
      final side = math.max(d.dx.abs(), d.dy.abs());
      d = Offset(side * d.dx.sign, side * d.dy.sign);
    }
    final rect = e.alt
        ? Rect.fromCenter(center: _start, width: d.dx.abs() * 2, height: d.dy.abs() * 2)
        : rectFromPoints(_start, _start + d);

    return switch (kind) {
      ShapeKind.rectangle => InkPath.rect(rect),
      ShapeKind.oval => InkPath.oval(rect),
      ShapeKind.star => InkPath.star(rect, 5, innerRatio: 0.45),
      ShapeKind.polygon => _polygon(rect, 6),
      ShapeKind.line => throw StateError('handled above'),
    };
  }

  InkPath _polygon(Rect r, int sides) {
    final c = r.center;
    return InkPath(
      closed: true,
      nodes: [
        for (var i = 0; i < sides; i++)
          BezierNode.anchor(Offset(
            c.dx + math.cos(-math.pi / 2 + i * 2 * math.pi / sides) * r.width / 2,
            c.dy + math.sin(-math.pi / 2 + i * 2 * math.pi / sides) * r.height / 2,
          )),
      ],
    );
  }

  @override
  void end(DrawingController c, ToolEvent e) => _shape = null;

  @override
  void cancel(DrawingController c) => _shape = null;
}
