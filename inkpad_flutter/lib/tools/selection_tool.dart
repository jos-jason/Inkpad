import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import 'tool.dart';

enum _Mode { none, move, anchor, handle, gradientStart, gradientEnd, scale, rotate, marquee }

/// Selects, moves, scales, rotates and node-edits. Combines Inkpad's WDSelectionTool
/// behaviour for elements with direct editing of the selected path's nodes.
class SelectionTool extends Tool {
  @override
  String get name => 'Select';

  _Mode _mode = _Mode.none;
  Offset _start = Offset.zero;
  Offset _last = Offset.zero;
  bool _checkpointed = false;

  // Node editing state.
  InkPath? _path;
  int _nodeIndex = -1;
  HandleKind _handle = HandleKind.anchor;
  ReflectionMode _originalMode = ReflectionMode.independent;

  InkStylable? _gradientShape;

  // Scaling state.
  Rect _scaleBounds = Rect.zero;
  int _scaleCorner = 0;
  Affine _applied = Affine.identity;
  Offset _grab = Offset.zero;

  /// Screen pixels between a selection corner and its scale handle, so the
  /// handles never sit on top of a shape's own corner points.
  static const handleOffset = 10.0;

  /// Scale handle positions (top-left, top-right, bottom-right, bottom-left)
  /// just outside [bounds].
  static List<Offset> scaleHandles(Rect bounds, double viewScale) {
    final o = handleOffset / viewScale;
    return [
      bounds.topLeft + Offset(-o, -o),
      bounds.topRight + Offset(o, -o),
      bounds.bottomRight + Offset(o, o),
      bounds.bottomLeft + Offset(-o, o),
    ];
  }

  /// Screen pixels from the top of the selection to its rotation knob.
  static const knobOffset = 28.0;

  /// The rotation knob, centered above [bounds].
  static Offset rotationKnob(Rect bounds, double viewScale) =>
      bounds.topCenter - Offset(0, knobOffset / viewScale);

  Offset _rotatePivot = Offset.zero;

  static List<Offset> _corners(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

  // Marquee state.
  Rect? marquee;
  Set<InkElement> _baseSelection = {};

  @override
  void begin(DrawingController c, ToolEvent e) {
    _start = _last = e.point;
    _checkpointed = false;
    final tol = e.slop();

    // 1. Gradient handles of the selected shape (Inkpad gave these priority).
    final shape = c.singleSelectedStylable;
    final fill = shape?.fill;
    if (shape != null && fill is InkGradient) {
      final g = fill.fitted(shape.bounds);
      _gradientShape = shape;
      if ((g.documentEnd - e.point).distance < tol) {
        _mode = _Mode.gradientEnd;
        return;
      }
      if ((g.documentStart - e.point).distance < tol) {
        _mode = _Mode.gradientStart;
        return;
      }
    }

    // 2. Handles/anchors of the single selected path. Double-clicking a point
    // adds or removes its handles (Inkpad's convertNode).
    final path = c.singleSelectedPath;
    if (path != null && _pickNode(path, e.point, tol)) {
      if (e.count == 2 && _mode == _Mode.anchor) {
        c.checkpoint();
        path.convertAnchor(_nodeIndex);
        c.changed();
        _mode = _Mode.none;
      }
      return;
    }

    // 3. Scale handles around the selection (Inkpad had a separate scale tool).
    final bounds = c.selectionBounds;
    if (bounds != null && c.activePath == null) {
      final handles = scaleHandles(bounds, e.viewScale);
      for (var i = 0; i < 4; i++) {
        if ((handles[i] - e.point).distance < tol) {
          _mode = _Mode.scale;
          _scaleBounds = bounds;
          _scaleCorner = i;
          _applied = Affine.identity;
          _grab = e.point;
          return;
        }
      }
    }

    // 4. The rotation knob: rotate about the selection's center.
    if (bounds != null && c.activePath == null && (rotationKnob(bounds, e.viewScale) - e.point).distance < tol) {
      _mode = _Mode.rotate;
      _rotatePivot = bounds.center;
      _applied = Affine.identity;
      _grab = e.point;
      return;
    }

    // 5. An element.
    final hit = c.elementAt(e.point, tol);
    if (hit != null) {
      if (e.shift && c.selection.contains(hit)) {
        c.selection.remove(hit);
        c.changed();
        _mode = _Mode.none;
        return;
      }
      if (!c.selection.contains(hit)) c.select(hit, extend: e.shift);
      _mode = _Mode.move;
      return;
    }

    // 6. Marquee on empty space.
    if (!e.shift) c.selectNone();
    _baseSelection = {...c.selection};
    _mode = _Mode.marquee;
    marquee = Rect.fromPoints(e.point, e.point);
  }

  bool _pickNode(InkPath path, Offset pt, double tol) {
    for (var i = 0; i < path.nodes.length; i++) {
      final n = path.nodes[i];
      HandleKind? kind;
      if ((n.anchorPoint - pt).distance < tol) {
        kind = HandleKind.anchor;
      } else if (n.hasOutPoint && (n.outPoint - pt).distance < tol) {
        kind = HandleKind.outPoint;
      } else if (n.hasInPoint && (n.inPoint - pt).distance < tol) {
        kind = HandleKind.inPoint;
      }
      if (kind != null) {
        _path = path;
        _nodeIndex = i;
        _handle = kind;
        _originalMode = n.reflectionMode;
        _mode = kind == HandleKind.anchor ? _Mode.anchor : _Mode.handle;
        return true;
      }
    }
    return false;
  }

  void _ensureCheckpoint(DrawingController c) {
    if (_checkpointed) return;
    c.checkpoint();
    _checkpointed = true;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    final delta = e.point - _last;
    _last = e.point;

    switch (_mode) {
      case _Mode.move:
        _ensureCheckpoint(c);
        c.transformSelection(Affine.translation(delta.dx, delta.dy));
      case _Mode.anchor:
        _ensureCheckpoint(c);
        final p = _path!;
        p.nodes[_nodeIndex] = p.nodes[_nodeIndex].moveAnchor(delta);
        c.changed();
      case _Mode.handle:
        _ensureCheckpoint(c);
        final p = _path!;
        final mode = e.alt ? ReflectionMode.independent : _originalMode;
        p.nodes[_nodeIndex] = p.nodes[_nodeIndex].moveControlHandle(_handle, e.point, mode);
        c.changed();
      case _Mode.gradientStart || _Mode.gradientEnd:
        _ensureCheckpoint(c);
        c.moveGradientHandle(_gradientShape!, start: _mode == _Mode.gradientStart, to: e.point);
      case _Mode.scale:
        _ensureCheckpoint(c);
        final t = _scaleTransform(e);
        // Apply only the change since the last move, so rounding never builds up.
        c.transformSelection(_applied.inverted().then(t));
        _applied = t;
      case _Mode.rotate:
        _ensureCheckpoint(c);
        var angle = sweptAngle(_rotatePivot, _grab, e.point);
        if (e.shift) angle = snapAngle(angle, RotateTool.snapDegrees);
        final t = Affine.rotationAbout(_rotatePivot, angle);
        c.transformSelection(_applied.inverted().then(t));
        _applied = t;
      case _Mode.marquee:
        marquee = rectFromPoints(_start, e.point);
        c.selection
          ..clear()
          ..addAll(_baseSelection)
          ..addAll(c.elementsInRect(marquee!));
        c.changed();
      case _Mode.none:
        break;
    }
  }

  /// Scales about the opposite corner (or the center with Alt), keeping
  /// proportions unless Shift is held.
  Affine _scaleTransform(ToolEvent e) {
    final corners = _corners(_scaleBounds);
    final corner = corners[_scaleCorner];
    final anchor = e.alt ? _scaleBounds.center : corners[(_scaleCorner + 2) % 4];
    // The handle sits just outside the corner, so follow the drag distance
    // rather than the pointer position, or the first move would jump.
    final target = corner + (e.point - _grab);
    final dx = corner.dx - anchor.dx, dy = corner.dy - anchor.dy;
    var sx = dx == 0 ? 1.0 : (target.dx - anchor.dx) / dx;
    var sy = dy == 0 ? 1.0 : (target.dy - anchor.dy) / dy;
    if (!e.shift) {
      final s = sx.abs() > sy.abs() ? sx : sy;
      sx = s;
      sy = s;
    }
    // Never collapse to zero (the transform must stay invertible).
    double clampScale(double v) => v.abs() < 0.01 ? (v.isNegative ? -0.01 : 0.01) : v;
    return Affine.scaleAbout(anchor, clampScale(sx), clampScale(sy));
  }

  @override
  void end(DrawingController c, ToolEvent e) => cancel(c);

  @override
  void cancel(DrawingController c) {
    _mode = _Mode.none;
    _path = null;
    _gradientShape = null;
    if (marquee != null) {
      marquee = null;
      c.changed();
    }
  }

  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    final m = marquee;
    if (m == null) return;
    canvas.drawRect(m, Paint()..color = const Color(0x220A84FF));
    canvas.drawRect(
      m,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / viewScale
        ..color = const Color(0xFF0A84FF),
    );
  }
}
