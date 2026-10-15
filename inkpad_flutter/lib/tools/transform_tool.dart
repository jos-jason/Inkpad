import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'tool.dart';

/// Transforms the selection around a pivot. Ported from WDTransformTool:
/// the pivot starts at the selection's center (and resets when the
/// selection changes); tap to move it, drag to transform.
abstract class TransformTool extends Tool {
  Offset? _pivot;
  Set<InkElement> _pivotSelection = {};

  Offset _start = Offset.zero;
  bool _moved = false;
  Affine _applied = Affine.identity;

  /// The transform for dragging from [start] to [point] around [pivot].
  Affine computeTransform(Offset start, Offset point, Offset pivot, {required bool shift});

  /// The pivot, reset to the selection's center whenever the selection changes.
  Offset? pivot(DrawingController c) {
    final bounds = c.selectionBounds;
    if (bounds == null) return null;
    if (_pivot == null || !_sameSelection(c)) {
      _pivot = bounds.center;
      _pivotSelection = {...c.selection};
    }
    return _pivot;
  }

  bool _sameSelection(DrawingController c) =>
      _pivotSelection.length == c.selection.length && _pivotSelection.containsAll(c.selection);

  @override
  void begin(DrawingController c, ToolEvent e) {
    _start = c.snapWithFeedback(e.point, e.snapTolerance).point;
    _moved = false;
    _applied = Affine.identity;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    final p = pivot(c);
    if (p == null) return;
    if (!_moved) {
      c.checkpoint();
      _moved = true;
    }
    final pt = c.snapWithFeedback(e.point, e.snapTolerance, skip: c.selection.contains).point;
    final t = computeTransform(_start, pt, p, shift: e.shift);
    // Apply only the change since the last move, so rounding never builds up.
    c.transformSelection(_applied.inverted().then(t));
    _applied = t;
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    if (_moved) {
      c.recordTransform(_applied);
      _moved = false;
      return;
    }
    // A tap moves the pivot.
    if (c.selection.isNotEmpty) {
      pivot(c);
      _pivot = _start; // snapped
      c.changed();
    }
  }

  @override
  void cancel(DrawingController c) {
    if (_moved) c.transformSelection(_applied.inverted());
    _moved = false;
    _applied = Affine.identity;
  }

  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    final p = pivot(c);
    if (p == null) return;
    final px = 1 / viewScale;
    const blue = Color(0xFF0A84FF), white = Color(0xFFFFFFFF);
    canvas.drawCircle(p, 7 * px, Paint()..color = white);
    canvas.drawCircle(p, 6 * px, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5 * px..color = blue);
    final line = Paint()
      ..color = blue
      ..strokeWidth = px;
    canvas.drawLine(p - Offset(10 * px, 0), p + Offset(10 * px, 0), line);
    canvas.drawLine(p - Offset(0, 10 * px), p + Offset(0, 10 * px), line);
  }
}

/// Ported from WDRotateTool: drag to rotate by the angle swept around the
/// pivot. Shift snaps to 15° steps.
class RotateTool extends TransformTool {
  @override
  String get name => 'Rotate';

  static const snapDegrees = 15.0;

  @override
  Affine computeTransform(Offset start, Offset point, Offset pivot, {required bool shift}) {
    var angle = sweptAngle(pivot, start, point);
    if (shift) angle = snapAngle(angle, snapDegrees);
    return Affine.rotationAbout(pivot, angle);
  }
}

/// Ported from WDScaleTool: drag towards or away from the pivot to scale.
/// Proportional by default (like Inkpad); Shift scales each axis freely.
class ScaleTool extends TransformTool {
  @override
  String get name => 'Scale';

  @override
  Affine computeTransform(Offset start, Offset point, Offset pivot, {required bool shift}) {
    final from = start - pivot, to = point - pivot;
    var sx = from.dx == 0 ? 1.0 : to.dx / from.dx;
    var sy = from.dy == 0 ? 1.0 : to.dy / from.dy;
    if (!shift) {
      // Keep proportions, preserving the direction of each axis.
      final s = sx.abs() > sy.abs() ? sx.abs() : sy.abs();
      sx = s * (sx < 0 ? -1 : 1);
      sy = s * (sy < 0 ? -1 : 1);
    }
    double safe(double v) => v.abs() < 0.01 ? (v.isNegative ? -0.01 : 0.01) : v;
    return Affine.scaleAbout(pivot, safe(sx), safe(sy));
  }
}
