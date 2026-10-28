import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import 'tool.dart';

enum _Mode { none, move, anchor, handle, gradientStart, gradientEnd, textStart, scale, rotate, marquee }

/// Selects, moves, scales, rotates and node-edits. Combines Inkpad's WDSelectionTool
/// behaviour for elements with direct editing of the selected path's nodes.
class SelectionTool extends Tool {
  @override
  String get name => 'Select';

  _Mode _mode = _Mode.none;
  Offset _start = Offset.zero;
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

  // Snapping while moving: the selection's own point under the pointer
  // (which then snaps to other points and edges), the bounds at the start
  // (whose corners snap to the grid), and how far it has moved so far.
  Offset? _grabPoint;
  Rect _startBounds = Rect.zero;
  Offset _moved = Offset.zero;
  Offset _anchorStart = Offset.zero;
  Offset _handleStart = Offset.zero;

  /// The nearest anchor point of the selection within [tol] of [p].
  static Offset? _ownPointNear(DrawingController c, Offset p, double tol) {
    Offset? best;
    var bestD = tol;
    void path(InkPath path) {
      for (final n in path.nodes) {
        final d = (n.anchorPoint - p).distance;
        if (d < bestD) {
          bestD = d;
          best = n.anchorPoint;
        }
      }
    }

    for (final e in c.selection) {
      for (final d in e.selfAndDescendants) {
        if (d is InkPath) path(d);
        if (d is InkCompoundPath) d.subpaths.forEach(path);
      }
    }
    return best;
  }

  @override
  void begin(DrawingController c, ToolEvent e) {
    _start = e.point;
    _checkpointed = false;
    final tol = e.slop();
    final bounds = c.selectionBounds;

    // 1. Controls of the selection, as in Inkpad's -hitResultForPoint: the
    // nearest one within reach wins; on a tie, the first in this order
    // (gradient ends, the selected point and its handles, other points,
    // then this port's scale handles and rotation knob).
    final controls = <(_Mode, Offset, int, HandleKind)>[];
    final shape = c.singleSelectedStylable;
    final fill = shape?.fill;
    if (shape != null && fill is InkGradient) {
      final g = fill.fitted(shape.bounds);
      _gradientShape = shape;
      controls
        ..add((_Mode.gradientStart, g.documentStart, -1, HandleKind.anchor))
        ..add((_Mode.gradientEnd, g.documentEnd, -1, HandleKind.anchor));
    }
    final textPath = c.selection.length == 1 && c.selection.first is InkTextPath ? c.selection.first as InkTextPath : null;
    final textStart = textPath?.pointAt(textPath.startOffset);
    if (textStart != null) controls.add((_Mode.textStart, textStart.$1, -1, HandleKind.anchor));
    // A live shape's points aren't edited directly (it moves instead).
    final path = c.singleSelectedPath;
    final editable = path != null && path.live == null ? path : null;
    if (editable != null) {
      final selected = c.selectedNodes[editable] ?? const <int>{};
      for (final i in selected) {
        if (i >= editable.nodes.length) continue;
        final n = editable.nodes[i];
        controls.add((_Mode.anchor, n.anchorPoint, i, HandleKind.anchor));
        if (n.hasOutPoint) controls.add((_Mode.handle, n.outPoint, i, HandleKind.outPoint));
        if (n.hasInPoint) controls.add((_Mode.handle, n.inPoint, i, HandleKind.inPoint));
      }
      for (final (i, n) in editable.nodes.indexed) {
        controls.add((_Mode.anchor, n.anchorPoint, i, HandleKind.anchor));
      }
    }
    if (bounds != null && c.activePath == null) {
      for (final (i, h) in scaleHandles(bounds, e.viewScale).indexed) {
        controls.add((_Mode.scale, h, i, HandleKind.anchor));
      }
      controls.add((_Mode.rotate, rotationKnob(bounds, e.viewScale), -1, HandleKind.anchor));
    }
    (_Mode, Offset, int, HandleKind)? best;
    var bestD = tol;
    for (final control in controls) {
      final d = (control.$2 - e.point).distance;
      if (d < bestD) {
        bestD = d;
        best = control;
      }
    }
    if (best != null) {
      final (mode, _, index, kind) = best;
      _mode = mode;
      switch (mode) {
        case _Mode.anchor || _Mode.handle:
          final p = editable!;
          final n = p.nodes[index];
          _path = p;
          _nodeIndex = index;
          _handle = kind;
          _originalMode = n.reflectionMode;
          _anchorStart = n.anchorPoint;
          _handleStart = kind == HandleKind.outPoint ? n.outPoint : (kind == HandleKind.inPoint ? n.inPoint : n.anchorPoint);
          if (mode == _Mode.anchor) {
            // Tap a point to select it (only it, unless Shift); its handles show.
            final selected = c.selectedNodes[p] ?? const <int>{};
            if (e.shift) {
              c.setSelectedNodes({p: selected.contains(index) ? ({...selected}..remove(index)) : {...selected, index}});
            } else if (!selected.contains(index)) {
              c.setSelectedNodes({p: {index}});
            }
            // Double-tap a point to add or remove its handles (Inkpad's convertNode).
            if (e.count == 2) {
              c.checkpoint();
              p.convertAnchor(index);
              c.setSelectedNodes({p: {index}});
              _mode = _Mode.none;
            }
          }
        case _Mode.scale:
          _scaleBounds = bounds!;
          _scaleCorner = index;
          _applied = Affine.identity;
          _grab = e.point;
        case _Mode.rotate:
          _rotatePivot = bounds!.center;
          _applied = Affine.identity;
          _grab = e.point;
        default:
          break;
      }
      return;
    }

    // 2. An element (the selected one's outline first, then the topmost).
    final hit = (shape != null && shape.hitTest(e.point, tol)) ? shape : c.elementAt(e.point, tol);
    if (hit != null) {
      if (e.shift && c.selection.contains(hit)) {
        c.selection.remove(hit);
        c.changed();
        _mode = _Mode.none;
        return;
      }
      // Double-click text to edit it (as in Inkpad).
      if (e.count == 2 && (hit is InkText || hit is InkTextPath)) {
        c.beginEditing(hit as InkStylable);
        _mode = _Mode.none;
        return;
      }
      if (!c.selection.contains(hit)) {
        c.select(hit, extend: e.shift);
      } else if (c.selectedNodes.isNotEmpty) {
        // Tapping the shape itself lets go of its selected point.
        c.setSelectedNodes({});
        c.select(hit);
      }
      _mode = _Mode.move;
      _moved = Offset.zero;
      _startBounds = c.selectionBounds ?? Rect.zero;
      _grabPoint = _ownPointNear(c, e.point, e.snapTolerance);
      return;
    }

    // 3. Marquee on empty space.
    if (!e.shift) c.selectNone();
    _baseSelection = {...c.selection};
    _mode = _Mode.marquee;
    marquee = Rect.fromPoints(e.point, e.point);
  }

  void _ensureCheckpoint(DrawingController c) {
    if (_checkpointed) return;
    c.checkpoint();
    _checkpointed = true;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    switch (_mode) {
      case _Mode.move:
        _ensureCheckpoint(c);
        var want = _snappedMove(c, e);
        if (e.constrain) want = constrain45(want);
        final step = want - _moved;
        _moved = want;
        c.transformSelection(Affine.translation(step.dx, step.dy));
      case _Mode.anchor:
        _ensureCheckpoint(c);
        final p = _path!;
        final i = _nodeIndex;
        final drag = e.constrain ? constrain45(e.point - _start) : e.point - _start;
        final to = c.snapWithFeedback(_anchorStart + drag, e.snapTolerance,
            skipNode: (path, j) => identical(path, p) && j == i).point;
        p.nodes[i] = p.nodes[i].moveAnchor(to - p.nodes[i].anchorPoint);
        c.changed();
      case _Mode.handle:
        _ensureCheckpoint(c);
        final p = _path!;
        final i = _nodeIndex;
        final mode = e.independent ? ReflectionMode.independent : _originalMode;
        // Follows the drag, so a handle grabbed off-center doesn't jump under the finger.
        final to = c.snapWithFeedback(_handleStart + (e.point - _start), e.snapTolerance, skipNode: (path, j) => identical(path, p) && j == i).point;
        p.nodes[i] = p.nodes[i].moveControlHandle(_handle, to, mode);
        c.changed();
      case _Mode.gradientStart || _Mode.gradientEnd:
        _ensureCheckpoint(c);
        c.moveGradientHandle(_gradientShape!, start: _mode == _Mode.gradientStart, to: e.point);
      case _Mode.scale:
        _ensureCheckpoint(c);
        final t = _scaleTransform(c, e);
        // Apply only the change since the last move, so rounding never builds up.
        c.transformSelection(_applied.inverted().then(t));
        _applied = t;
      case _Mode.rotate:
        _ensureCheckpoint(c);
        var angle = sweptAngle(_rotatePivot, _grab, e.point);
        if (e.constrain) angle = snapAngle(angle, RotateTool.snapDegrees);
        final t = Affine.rotationAbout(_rotatePivot, angle);
        c.transformSelection(_applied.inverted().then(t));
        _applied = t;
      case _Mode.textStart:
        _ensureCheckpoint(c);
        final tp = c.selection.first as InkTextPath;
        tp.startOffset = tp.offsetNearest(e.point);
        c.changed();
      case _Mode.marquee:
        // Option or a second finger: from the middle out.
        marquee = e.independent ? rectFromPoints(_start * 2 - e.point, e.point) : rectFromPoints(_start, e.point);
        c.selection
          ..clear()
          ..addAll(_baseSelection)
          ..addAll(c.elementsInRect(marquee!));
        c.changed();
      case _Mode.none:
        break;
    }
  }

  /// How far to move the selection: the drag, snapped. A point of the
  /// selection under the pointer snaps to other points and edges; failing
  /// that, the nearest corner of its bounds snaps to the grid (Inkpad's
  /// -offsetSelection:).
  Offset _snappedMove(DrawingController c, ToolEvent e) {
    final raw = e.point - _start;
    final grab = _grabPoint;
    if (grab != null) {
      final r = c.snap(grab + raw, e.snapTolerance, skip: c.selection.contains, grid: false);
      if (r.snapped) {
        c.snapFeedback = r;
        return r.point - grab;
      }
    }
    c.snapFeedback = null;
    if (c.drawing.snapToGrid) return c.gridOffset(_startBounds, raw);
    return raw;
  }

  /// Scales about the opposite corner (or the center with Alt), keeping
  /// proportions unless Shift is held.
  Affine _scaleTransform(DrawingController c, ToolEvent e) {
    final corners = _corners(_scaleBounds);
    final corner = corners[_scaleCorner];
    final anchor = e.alt ? _scaleBounds.center : corners[(_scaleCorner + 2) % 4];
    // The handle sits just outside the corner, so follow the drag distance
    // rather than the pointer position, or the first move would jump. The
    // corner snaps (to anything but the selection itself).
    final target = c.snapWithFeedback(corner + (e.point - _grab), e.snapTolerance, skip: c.selection.contains).point;
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
  void end(DrawingController c, ToolEvent e) {
    // Remember whole-selection transforms for Transform Again.
    if (_checkpointed) {
      switch (_mode) {
        case _Mode.move:
          c.recordTransform(Affine.translation(_moved.dx, _moved.dy));
        case _Mode.scale || _Mode.rotate:
          c.recordTransform(_applied);
        default:
          break;
      }
    }
    cancel(c);
  }

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
