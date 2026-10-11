import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'tool.dart';

/// Rotates the selection around a pivot. Ported from WDRotateTool and
/// WDTransformTool: tap to move the pivot (it starts at the selection's
/// center), drag to rotate by the angle swept around it. Shift snaps to
/// 15° steps.
class RotateTool extends Tool {
  @override
  String get name => 'Rotate';

  static const snapDegrees = 15.0;

  Offset? _pivot;
  Set<InkElement> _pivotSelection = {};

  Offset _start = Offset.zero;
  bool _moved = false;
  Affine _applied = Affine.identity;

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
    _start = e.point;
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
    var angle = sweptAngle(p, _start, e.point);
    if (e.shift) angle = snapAngle(angle, snapDegrees);
    final t = Affine.rotationAbout(p, angle);
    c.transformSelection(_applied.inverted().then(t));
    _applied = t;
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    // A tap moves the pivot.
    if (!_moved && c.selection.isNotEmpty) {
      pivot(c);
      _pivot = e.point;
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
