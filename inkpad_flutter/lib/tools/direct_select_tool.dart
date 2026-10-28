import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'tool.dart';

enum _Mode { none, objects, points, handle, marquee }

/// Multi-select, after Inkpad's group-select tool (the arrow with a plus):
/// every tap adds to the selection or, on something already selected,
/// takes it away.
///  * tap an object to add it; tap it again to remove it;
///  * drag a selected object to move all the selected objects;
///  * selected objects show their points: tap a point to add it, tap it
///    again to remove it (points of other objects can be picked too, from
///    closer);
///  * drag a selected point to move all the selected points (with several
///    objects selected, any drag moves the objects whole);
///  * drag a selected point's handle to reshape (Alt or a second finger
///    breaks the symmetry); double-tap a point to add or remove handles,
///    or a handle to remove just that one;
///  * drag on empty space to add the points in a rectangle; tap empty
///    space to select nothing;
///  * Delete removes the selected points (or, with none, the objects).
class DirectSelectTool extends Tool {
  @override
  String get name => 'Multi-Select';

  _Mode _mode = _Mode.none;
  Offset _start = Offset.zero;
  bool _checkpointed = false;
  bool _moved = false;

  /// What the touch landed on, to take it away again if it was already
  /// selected and the touch turns out to be a tap.
  InkElement? _tappedObject;
  (InkPath, int)? _tappedPoint;
  bool _wasSelected = false;

  InkPath? _handlePath;
  int _handleIndex = 0;
  HandleKind _handle = HandleKind.inPoint;
  ReflectionMode _reflection = ReflectionMode.independent;
  Offset _handleStart = Offset.zero;

  Rect? marquee;
  Map<InkPath, Set<int>> _base = {};

  /// The point grabbed (it snaps; the other selected points follow), and
  /// how far things have moved.
  Offset? _grabAnchor;
  Offset _dragged = Offset.zero;
  Rect? _bounds;

  /// The paths whose points can be edited, with the object each belongs
  /// to (live shapes keep their dimensions, so their points can't).
  static Map<InkPath, InkElement> _editablePaths(DrawingController c) => {
        for (final MapEntry(key: p, value: owner) in c.pathOwners().entries)
          if (p.live == null) p: owner,
      };

  @override
  void begin(DrawingController c, ToolEvent e) {
    _start = e.point;
    _checkpointed = false;
    _moved = false;
    _grabAnchor = null;
    _dragged = Offset.zero;
    _bounds = null;
    _tappedObject = null;
    _tappedPoint = null;
    final tol = e.slop();
    final paths = _editablePaths(c);

    // 1. The nearest handle of a selected point, or point: points of
    // selected objects within reach, others only from closer (so a tap in
    // the middle of a small object picks the object).
    (InkPath, int, HandleKind)? best;
    var bestD = double.infinity;
    void consider(InkPath path, int i, HandleKind kind, Offset at, double reach) {
      final d = (at - e.point).distance;
      if (d < reach && d < bestD) {
        bestD = d;
        best = (path, i, kind);
      }
    }

    for (final MapEntry(key: path, value: indices) in c.selectedNodes.entries) {
      for (final i in indices) {
        if (i >= path.nodes.length) continue;
        final n = path.nodes[i];
        if (n.hasOutPoint) consider(path, i, HandleKind.outPoint, n.outPoint, tol);
        if (n.hasInPoint) consider(path, i, HandleKind.inPoint, n.inPoint, tol);
      }
    }
    // Topmost first, so it wins a tie.
    for (final MapEntry(key: path, value: owner) in paths.entries.toList().reversed) {
      final reach = c.selection.contains(owner) ? tol : tol / 2;
      for (final (i, n) in path.nodes.indexed) {
        consider(path, i, HandleKind.anchor, n.anchorPoint, reach);
      }
    }
    final picked = best;
    if (picked != null && picked.$3 != HandleKind.anchor) {
      final (path, i, kind) = picked;
      final n = path.nodes[i];
      if (e.count == 2) {
        // Double-tap a handle: remove just that half.
        c.checkpoint();
        path.nodes[i] = kind == HandleKind.outPoint ? n.chopOutHandle() : n.chopInHandle();
        c.changed();
        _mode = _Mode.none;
        return;
      }
      _mode = _Mode.handle;
      _handlePath = path;
      _handleIndex = i;
      _handle = kind;
      _reflection = n.reflectionMode;
      _handleStart = kind == HandleKind.outPoint ? n.outPoint : n.inPoint;
      return;
    }

    // 2. A point: added at once (so a drag moves it with the others); a
    // tap on one already selected takes it away.
    if (picked != null) {
      final (path, i, _) = picked;
      if (e.count == 2) {
        // Double-tap: add or remove its handles (Inkpad's convertNode).
        c.checkpoint();
        path.convertAnchor(i);
        c.selectPoint(path, i, paths[path]!);
        _mode = _Mode.none;
        return;
      }
      _wasSelected = c.selectedNodes[path]?.contains(i) ?? false;
      if (!_wasSelected) c.selectPoint(path, i, paths[path]!);
      _tappedPoint = (path, i);
      _mode = _Mode.points;
      _grabAnchor = path.nodes[i].anchorPoint;
      return;
    }

    // A selected live shape's point (Make mode): its points aren't edited
    // directly, so say how to.
    for (final MapEntry(key: path, value: owner) in c.pathOwners().entries) {
      if (path.live == null || !c.selection.contains(owner)) continue;
      if (path.anchorIndexAt(e.point, tol) != null) {
        c.liveShapeHint();
        _mode = _Mode.none;
        return;
      }
    }

    // 3. An object: added at once; a tap on one already selected takes it
    // away.
    final hit = c.elementAt(e.point, tol);
    if (hit != null) {
      _wasSelected = c.selection.contains(hit);
      if (!_wasSelected) c.addToSelection(hit);
      _tappedObject = hit;
      _mode = _Mode.objects;
      return;
    }

    // 4. Empty space: a marquee adds the points inside it; a tap selects
    // nothing.
    _base = {for (final e in c.selectedNodes.entries) e.key: {...e.value}};
    marquee = Rect.fromPoints(e.point, e.point);
    _mode = _Mode.marquee;
  }

  void _ensureCheckpoint(DrawingController c) {
    if (_checkpointed) return;
    c.checkpoint();
    _checkpointed = true;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    if (e.point != _start) _moved = true;
    var drag = e.point - _start;
    if (e.constrain) drag = constrain45(drag);
    // With several objects selected, a drag always moves them whole (every
    // point of every one), never just some points of one.
    final mode = _mode == _Mode.points && c.selection.length > 1 ? _Mode.objects : _mode;
    switch (mode) {
      case _Mode.objects:
        _ensureCheckpoint(c);
        var want = drag;
        if (c.drawing.snapToGrid) want = c.gridOffset(_bounds ??= c.selectionBounds ?? Rect.zero, want);
        final step = want - _dragged;
        _dragged = want;
        c.transformSelection(Affine.translation(step.dx, step.dy));
      case _Mode.points:
        _ensureCheckpoint(c);
        var want = drag;
        final grab = _grabAnchor;
        if (grab != null) {
          final selected = c.selectedNodes;
          final r = c.snapWithFeedback(grab + want, e.snapTolerance, skipNode: (p, i) => selected[p]?.contains(i) ?? false);
          want = r.point - grab;
        }
        final step = want - _dragged;
        _dragged = want;
        for (final MapEntry(key: path, value: indices) in c.selectedNodes.entries) {
          for (final i in indices) {
            if (i < path.nodes.length) path.nodes[i] = path.nodes[i].moveAnchor(step);
          }
        }
        c.changed();
      case _Mode.handle:
        _ensureCheckpoint(c);
        final p = _handlePath!;
        final i = _handleIndex;
        final mode = e.independent ? ReflectionMode.independent : _reflection;
        // Follows the drag, so a handle grabbed off-center doesn't jump under the finger.
        final to = c.snapWithFeedback(_handleStart + (e.point - _start), e.snapTolerance, skipNode: (path, j) => identical(path, p) && j == i).point;
        p.nodes[i] = p.nodes[i].moveControlHandle(_handle, to, mode);
        c.changed();
      case _Mode.marquee:
        final r = rectFromPoints(_start, e.point);
        marquee = r;
        final next = {for (final e in _base.entries) e.key: {...e.value}};
        for (final path in _editablePaths(c).keys) {
          for (var i = 0; i < path.nodes.length; i++) {
            if (r.contains(path.nodes[i].anchorPoint)) (next[path] ??= {}).add(i);
          }
        }
        c.setSelectedNodes(next, keepObjects: true);
      case _Mode.none:
        break;
    }
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    if (!_moved) {
      // A tap on something already selected takes it away; on empty space,
      // selects nothing.
      final point = _tappedPoint, object = _tappedObject;
      if (_mode == _Mode.points && _wasSelected && point != null) {
        c.deselectPoint(point.$1, point.$2);
      } else if (_mode == _Mode.objects && _wasSelected && object != null) {
        c.removeFromSelection(object);
      } else if (_mode == _Mode.marquee) {
        c.selectNone();
      }
    }
    cancel(c);
  }

  @override
  void cancel(DrawingController c) {
    _mode = _Mode.none;
    _handlePath = null;
    _bounds = null;
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
