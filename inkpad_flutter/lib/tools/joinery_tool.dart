import '../controller/drawing_controller.dart';
import 'tool.dart';

/// Click a straight edge of a part to cut fingers into it or add tabs; click
/// a straight line to put slots along it (for the tabs of another part).
class JoineryTool extends Tool {
  @override
  String get name => 'Joinery';

  @override
  void end(DrawingController c, ToolEvent e) {
    final tol = e.slop(10);
    final owners = c.pathOwners();
    // Topmost first.
    for (final path in owners.keys.toList().reversed) {
      final hit = path.edgeHit(e.point, tol);
      if (hit == null) continue;
      final seg = path.segments.elementAt(hit.$1);
      if (!seg.isStraight) {
        c.showHint('Joints go on straight edges.');
        return;
      }
      if (!path.closed && path.nodes.length != 2) {
        c.showHint('Slots go along a single straight line.');
        return;
      }
      c.select(owners[path]!);
      c.jointRequest.value = JointTarget(path, hit.$1);
      return;
    }
  }
}
