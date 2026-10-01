import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import 'tool.dart';

enum _Mode { none, move, anchor, handle, gradientStart, gradientEnd, marquee }

/// Selects, moves and node-edits. Combines Inkpad's WDSelectionTool
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

    // 2. Handles/anchors of the single selected path.
    final path = c.singleSelectedPath;
    if (path != null && _pickNode(path, e.point, tol)) return;

    // 3. An element.
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

    // 4. Marquee on empty space.
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
