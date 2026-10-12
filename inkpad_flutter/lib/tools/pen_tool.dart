import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/element.dart';
import 'tool.dart';

/// Click to add corner points, drag to pull out smooth handles.
/// Ported from WDPenTool:
///  * tap/drag near the first node closes the path;
///  * dragging from the last node re-shapes its out handle;
///  * tapping the last node without dragging finishes the path
///    (Inkpad used a double tap);
///  * starting on an end point of a selected open path continues it.
class PenTool extends Tool {
  @override
  String get name => 'Pen';

  BezierNode? _replacement;
  List<BezierNode> _baseNodes = [];
  bool _updatingOldNode = false;
  bool _closingPath = false;
  bool _moved = false;
  ReflectionMode _oldMode = ReflectionMode.independent;

  @override
  void begin(DrawingController c, ToolEvent e) {
    final tol = e.slop(12);
    _updatingOldNode = _closingPath = _moved = false;
    c.checkpoint();

    var active = c.activePath;

    // Continue an existing open path from one of its end points.
    final selected = c.singleSelectedPath;
    if (active == null && selected != null && !selected.closed && selected.nodes.isNotEmpty) {
      if ((selected.nodes.first.anchorPoint - e.point).distance < tol && selected.nodes.length > 1) {
        selected.reverse();
      }
      if ((selected.nodes.last.anchorPoint - e.point).distance < tol) {
        active = c.activePath = selected;
      }
    }

    if (active != null && (active.nodes.last.anchorPoint - e.point).distance < tol) {
      _replacement = active.nodes.last.chopOutHandle();
      _updatingOldNode = true;
      _oldMode = active.nodes.last.reflectionMode;
    } else if (active != null &&
        active.nodes.length > 1 &&
        (active.nodes.first.anchorPoint - e.point).distance < tol) {
      _replacement = active.nodes.first;
      _oldMode = _replacement!.reflectionMode;
      _closingPath = true;
    } else {
      _replacement = BezierNode.anchor(c.snapWithFeedback(e.point, e.snapTolerance).point);
      if (active == null) {
        active = c.styledPath(InkPath(nodes: []));
        c.addElement(active);
        c.activePath = active;
      }
    }

    c.select(active);
    _baseNodes = List.of(active.nodes);
    _apply(c);
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    _moved = true;
    final r = _replacement!;
    // Handles snap too, but not onto the node they belong to.
    final index = _closingPath ? 0 : (_updatingOldNode ? _baseNodes.length - 1 : _baseNodes.length);
    final active = c.activePath;
    final pt = c.snapWithFeedback(e.point, e.snapTolerance, skipNode: (p, i) => identical(p, active) && i == index).point;
    if (_closingPath) {
      final mode = e.alt ? ReflectionMode.independent : _oldMode;
      _replacement = r.setInPoint(pt, mode);
    } else {
      final mode = e.alt
          ? ReflectionMode.independent
          : (_updatingOldNode ? _oldMode : ReflectionMode.reflect);
      _replacement = r.moveControlHandle(HandleKind.outPoint, pt, mode);
    }
    _apply(c);
  }

  /// Writes the in-progress node into the active path.
  void _apply(DrawingController c) {
    final path = c.activePath;
    if (path == null) return;
    final nodes = List.of(_baseNodes);
    if (_updatingOldNode) {
      nodes[nodes.length - 1] = _replacement!;
    } else if (_closingPath) {
      nodes[0] = _replacement!;
    } else {
      nodes.add(_replacement!);
    }
    path.nodes = nodes;
    c.changed();
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    final path = c.activePath;
    if (path != null) {
      if (_closingPath) {
        path.closed = true;
        c.activePath = null;
      } else if (_updatingOldNode && !_moved) {
        // Tap on the last node: finish this path.
        c.finishActivePath();
      }
    }
    _replacement = null;
    c.changed();
  }

  @override
  void cancel(DrawingController c) {
    final path = c.activePath;
    if (path != null && _replacement != null) {
      path.nodes = _baseNodes;
      c.changed();
    }
    _replacement = null;
  }
}
