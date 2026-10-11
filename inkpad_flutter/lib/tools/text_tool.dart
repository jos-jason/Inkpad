import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'tool.dart';

/// Creates and edits text. Ported from WDTextTool:
///  * drag to make a text box that wraps to its width (Inkpad's text);
///  * tap empty space for point text, which grows from where you tapped;
///  * tap existing text to edit it.
class TextTool extends Tool {
  @override
  String get name => 'Text';

  Offset _start = Offset.zero;
  Rect? box;

  @override
  void begin(DrawingController c, ToolEvent e) {
    c.endEditing();
    _start = e.point;
    box = null;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    if (box == null) c.selectNone();
    box = rectFromPoints(_start, e.point);
    c.changed();
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    final r = box;
    box = null;
    if (r != null && r.width * e.viewScale > 4) {
      c.createText(area: r);
      return;
    }
    final hit = textAt(c, e.point, e.slop());
    if (hit != null) {
      c.beginEditing(hit);
    } else {
      c.createText(at: e.point);
    }
  }

  /// The topmost editable text (or text on a path) under [p].
  static InkStylable? textAt(DrawingController c, Offset p, double tol) {
    for (final layer in c.drawing.layers.reversed) {
      if (!layer.editable) continue;
      for (final e in layer.elements.reversed) {
        if ((e is InkText || e is InkTextPath) && e.hitTest(p, tol)) return e as InkStylable;
      }
    }
    return null;
  }

  @override
  void cancel(DrawingController c) {
    box = null;
    c.changed();
  }

  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    final r = box;
    if (r == null) return;
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / viewScale
        ..color = const Color(0xFF0A84FF),
    );
  }
}
