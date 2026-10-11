import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'tool.dart';

enum _Mode { none, nodes, handle, marquee }

/// Selects and edits individual anchor points, on any path — including
/// inside groups, compound paths and masks. Inkpad's subselection editing as
/// its own tool:
///  * click a point to select it (Shift adds or removes);
///  * drag to move all selected points;
///  * drag a selected point's handle to reshape (Alt breaks the symmetry);
///  * click a path's outline to select all its points;
///  * drag on empty space to select points in a rectangle;
///  * double-click a point to add or remove its handles;
///  * Delete removes the selected points.
class DirectSelectTool extends Tool {
  @override
  String get name => 'Direct Select';

  _Mode _mode = _Mode.none;
  Offset _start = Offset.zero, _last = Offset.zero;
  bool _checkpointed = false;

  InkPath? _handlePath;
  int _handleIndex = 0;
  HandleKind _handle = HandleKind.inPoint;
  ReflectionMode _reflection = ReflectionMode.independent;

  Rect? marquee;
  Map<InkPath, Set<int>> _base = {};

  @override
  void begin(DrawingController c, ToolEvent e) {
    _start = _last = e.point;
    _checkpointed = false;
    final tol = e.slop();
    final paths = c.pathOwners().keys.toList().reversed; // topmost first

    // 1. Handles of selected points.
    for (final MapEntry(key: path, value: indices) in c.selectedNodes.entries) {
      for (final i in indices) {
        if (i >= path.nodes.length) continue;
        final n = path.nodes[i];
        final kind = n.hasOutPoint && (n.outPoint - e.point).distance < tol
            ? HandleKind.outPoint
            : n.hasInPoint && (n.inPoint - e.point).distance < tol
                ? HandleKind.inPoint
                : null;
        if (kind != null) {
          _mode = _Mode.handle;
          _handlePath = path;
          _handleIndex = i;
          _handle = kind;
          _reflection = n.reflectionMode;
          return;
        }
      }
    }

    // 2. Anchor points.
    for (final path in paths) {
      final i = path.anchorIndexAt(e.point, tol);
      if (i == null) continue;
      if (e.count == 2) {
        c.checkpoint();
        path.convertAnchor(i);
        c.setSelectedNodes({path: {i}});
        _mode = _Mode.none;
        return;
      }
      final next = _copy(c.selectedNodes);
      final selected = next[path]?.contains(i) ?? false;
      if (e.shift) {
        selected ? next[path]!.remove(i) : (next[path] ??= {}).add(i);
      } else if (!selected) {
        next
          ..clear()
          ..[path] = {i};
      }
      c.setSelectedNodes(next);
      _mode = _Mode.nodes;
      return;
    }

    // 3. A path's outline or fill: select all its points.
    for (final path in paths) {
      if (!path.hitTest(e.point, tol) && !_outlineHit(path, e.point, tol)) continue;
      final next = e.shift ? _copy(c.selectedNodes) : <InkPath, Set<int>>{};
      next[path] = {for (var i = 0; i < path.nodes.length; i++) i};
      c.setSelectedNodes(next);
      _mode = _Mode.nodes;
      return;
    }

    // 4. Marquee.
    _base = e.shift ? _copy(c.selectedNodes) : {};
    if (!e.shift) c.setSelectedNodes({});
    marquee = Rect.fromPoints(e.point, e.point);
    _mode = _Mode.marquee;
  }

  /// Subpaths and mask paths have no style of their own, so test the line.
  bool _outlineHit(InkPath path, Offset p, double tol) => path.edgeHit(p, tol) != null;

  static Map<InkPath, Set<int>> _copy(Map<InkPath, Set<int>> m) => {for (final e in m.entries) e.key: {...e.value}};

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
      case _Mode.nodes:
        _ensureCheckpoint(c);
        for (final MapEntry(key: path, value: indices) in c.selectedNodes.entries) {
          for (final i in indices) {
            if (i < path.nodes.length) path.nodes[i] = path.nodes[i].moveAnchor(delta);
          }
        }
        c.changed();
      case _Mode.handle:
        _ensureCheckpoint(c);
        final p = _handlePath!;
        final mode = e.alt ? ReflectionMode.independent : _reflection;
        p.nodes[_handleIndex] = p.nodes[_handleIndex].moveControlHandle(_handle, e.point, mode);
        c.changed();
      case _Mode.marquee:
        final r = rectFromPoints(_start, e.point);
        marquee = r;
        final next = _copy(_base);
        for (final path in c.pathOwners().keys) {
          for (var i = 0; i < path.nodes.length; i++) {
            if (r.contains(path.nodes[i].anchorPoint)) (next[path] ??= {}).add(i);
          }
        }
        c.setSelectedNodes(next);
      case _Mode.none:
        break;
    }
  }

  @override
  void end(DrawingController c, ToolEvent e) => cancel(c);

  @override
  void cancel(DrawingController c) {
    _mode = _Mode.none;
    _handlePath = null;
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
