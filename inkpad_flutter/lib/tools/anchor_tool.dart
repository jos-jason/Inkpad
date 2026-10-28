import '../controller/drawing_controller.dart';
import '../model/element.dart';
import 'tool.dart';

/// Adds and removes anchor points. Ported from WDAddAnchorTool:
///  * click a path's edge to insert an anchor there (the curve keeps its shape);
///  * click an anchor of the selected path to delete it;
///  * click an unselected path's anchor to select that path;
///  * Alt/Option-click an anchor to toggle it between corner and smooth
///    (Inkpad's convertNode).
class AnchorTool extends Tool {
  @override
  String get name => 'Add/Delete Point';

  @override
  void begin(DrawingController c, ToolEvent e) {
    final tol = e.slop(10);

    // Anchors of the selected path take priority over everything else.
    final selected = c.singleSelectedPath;
    if (selected != null) {
      final i = selected.anchorIndexAt(e.point, tol);
      if (i != null && selected.live != null) return c.liveShapeHint();
      if (i != null) {
        if (e.alt) {
          c.checkpoint();
          selected.convertAnchor(i);
          c.changed();
        } else if (selected.nodes.length > 2) {
          c.checkpoint();
          selected.deleteAnchor(i);
          c.changed();
        }
        return;
      }
    }

    // Otherwise find the topmost path whose anchor or edge is under the pointer.
    for (final layer in c.drawing.layers.reversed) {
      if (!layer.editable) continue;
      for (final path in layer.elements.reversed.whereType<InkPath>()) {
        if (path.anchorIndexAt(e.point, tol) != null) {
          c.select(path);
          return;
        }
        final hit = path.edgeHit(e.point, tol + (path.stroke?.width ?? 0) / 2);
        if (hit != null && path.live != null) {
          c.select(path);
          return c.liveShapeHint();
        }
        if (hit != null) {
          c.checkpoint();
          path.insertAnchor(hit.$1, hit.$2);
          c.select(path);
          return;
        }
      }
    }
  }
}
