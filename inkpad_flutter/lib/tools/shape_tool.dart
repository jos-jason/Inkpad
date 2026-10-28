import 'dart:math' as math;
import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'tool.dart';

enum ShapeKind { rectangle, oval, star, polygon, spiral, line }

/// Drag out a shape. Ported from WDShapeTool.
/// Shift constrains proportions (or 45° for lines); Alt draws from the center.
class ShapeTool extends Tool {
  final ShapeKind kind;

  // Options, as in Inkpad's shape tool options panel.
  double cornerRadius = 0;
  int starPoints = 5;
  double starInnerRatio = 0.45;
  int polygonSides = 6;

  /// How quickly a spiral winds in, 10–99%.
  double spiralDecay = 80;

  ShapeTool(this.kind);

  @override
  String get name => switch (kind) {
        ShapeKind.rectangle => 'Rectangle',
        ShapeKind.oval => 'Oval',
        ShapeKind.star => 'Star',
        ShapeKind.polygon => 'Polygon',
        ShapeKind.spiral => 'Spiral',
        ShapeKind.line => 'Line',
      };

  Offset _start = Offset.zero;
  InkPath? _shape;

  @override
  void begin(DrawingController c, ToolEvent e) {
    _start = c.snapWithFeedback(e.point, e.snapTolerance).point;
    _shape = null;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    final built = _build(c, e);
    if (_shape == null) {
      c.checkpoint();
      _shape = c.styledPath(built);
      if (kind == ShapeKind.line || kind == ShapeKind.spiral) _shape!.fill = null;
      c.addElement(_shape!);
      c.select(_shape!);
    } else if (built.live != null) {
      _shape!.live = built.live;
    } else {
      _shape!
        ..nodes = built.nodes
        ..closed = built.closed;
    }
    c.changed();
  }

  InkPath _build(DrawingController c, ToolEvent e) {
    // Snap the dragged corner, ignoring the shape being drawn.
    var end = c.snapWithFeedback(e.point, e.snapTolerance, skip: (el) => identical(el, _shape)).point;

    if (kind == ShapeKind.spiral) return _spiral(_start, end);
    // Make mode: shapes keep their dimensions.
    final make = c.drawing.makeMode;

    if (kind == ShapeKind.line) {
      if (e.constrain) {
        final d = end - _start;
        final angle = (math.atan2(d.dy, d.dx) / (math.pi / 4)).round() * (math.pi / 4);
        end = _start + Offset(math.cos(angle), math.sin(angle)) * d.distance;
      }
      if (make) return InkPath.live(LiveShape.line(_start, end));
      return InkPath(nodes: [BezierNode.anchor(_start), BezierNode.anchor(end)]);
    }

    var d = end - _start;
    if (e.constrain) {
      final side = math.max(d.dx.abs(), d.dy.abs());
      d = Offset(side * d.dx.sign, side * d.dy.sign);
    }
    final rect = e.alt
        ? Rect.fromCenter(center: _start, width: d.dx.abs() * 2, height: d.dy.abs() * 2)
        : rectFromPoints(_start, _start + d);

    if (make) {
      return InkPath.live(LiveShape.inRect(
        switch (kind) {
          ShapeKind.rectangle => LiveKind.rectangle,
          ShapeKind.oval => LiveKind.ellipse,
          ShapeKind.star => LiveKind.star,
          _ => LiveKind.polygon,
        },
        rect,
        cornerRadius: cornerRadius,
        sides: kind == ShapeKind.star ? starPoints : polygonSides,
        innerRatio: starInnerRatio,
      ));
    }
    return switch (kind) {
      ShapeKind.rectangle => InkPath.roundedRect(rect, cornerRadius),
      ShapeKind.oval => InkPath.oval(rect),
      ShapeKind.star => InkPath.star(rect, starPoints, innerRatio: starInnerRatio),
      ShapeKind.polygon => _polygon(rect, polygonSides),
      ShapeKind.line || ShapeKind.spiral => throw StateError('handled above'),
    };
  }

  /// A logarithmic spiral from [center] whose outer end is at [end].
  /// Ported from WDShapeTool's spiral: 20 eighth-turn segments.
  InkPath _spiral(Offset center, Offset end) {
    final radius = (end - center).distance;
    const segments = 20;
    final b = 1 - spiralDecay / 100;
    final a = radius / math.exp(b * segments * math.pi / 4);
    final offsetAngle = math.atan2(end.dy - center.dy, end.dx - center.dx) + math.pi;
    const deltaT = math.pi / 4 / 3;
    final nodes = <BezierNode>[];
    for (var s = 0; s <= segments; s++) {
      final t = s * math.pi / 4;
      final f = a * math.exp(b * t);
      final p = Offset(f * math.cos(t), f * math.sin(t));
      final d = Offset(a * b * math.exp(b * t) * math.cos(t) - f * math.sin(t), f * math.cos(t) + a * b * math.exp(b * t) * math.sin(t));
      nodes.add(BezierNode(p - d * deltaT, p, p + d * deltaT));
    }
    return InkPath(nodes: nodes)..transform(Affine.rotation(offsetAngle).then(Affine.translation(center.dx, center.dy)));
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
