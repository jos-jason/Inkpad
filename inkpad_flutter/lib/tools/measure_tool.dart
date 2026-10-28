import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle, FontWeight;

import '../controller/drawing_controller.dart';
import '../model/units.dart';
import 'tool.dart';

/// Measures between two points (which snap like everything else): the
/// distance, how far across and down, and the angle. Shift keeps the angle
/// to 15° steps. The measurement stays until the next one.
class MeasureTool extends Tool {
  @override
  String get name => 'Measure';

  Offset? from, to;

  @override
  void begin(DrawingController c, ToolEvent e) {
    from = c.snapWithFeedback(e.point, e.snapTolerance).point;
    to = from;
    c.changed();
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    final a = from;
    if (a == null) return;
    var b = c.snapWithFeedback(e.point, e.snapTolerance).point;
    if (e.constrain) {
      final d = b - a;
      final step = math.pi / 12;
      final angle = (math.atan2(d.dy, d.dx) / step).round() * step;
      b = a + Offset(math.cos(angle), math.sin(angle)) * d.distance;
    }
    to = b;
    c.changed();
  }

  @override
  void cancel(DrawingController c) {
    from = to = null;
    c.changed();
  }

  /// The measurement as text in the drawing's unit.
  static String describe(Offset a, Offset b, LengthFormat lengths) {
    final d = b - a;
    final angle = -math.atan2(d.dy, d.dx) * 180 / math.pi; // counterclockwise, as on a protractor
    return '${lengths.format(d.distance)}  ·  ${formatDegrees(angle)}\n'
        '↔ ${lengths.format(d.dx.abs())}   ↕ ${lengths.format(d.dy.abs())}';
  }

  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    final a = from, b = to;
    if (a == null || b == null || (b - a).distance < 1e-9) return;
    final px = 1 / viewScale;
    const color = Color(0xFFE0457B);
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5 * px;
    canvas.drawLine(a, b, line);
    final d = b - a;
    final n = Offset(-d.dy, d.dx) / d.distance * 6 * px;
    canvas.drawLine(a - n, a + n, line);
    canvas.drawLine(b - n, b + n, line);

    final text = TextPainter(
      text: TextSpan(
        text: describe(a, b, c.drawing.lengths),
        style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: 12 * px, fontWeight: FontWeight.w600, height: 1.3),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final mid = (a + b) / 2 + Offset(10 * px, 10 * px);
    final box = Rect.fromLTWH(mid.dx, mid.dy, text.width + 12 * px, text.height + 8 * px);
    canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(6 * px)), Paint()..color = color);
    text.paint(canvas, box.topLeft + Offset(6 * px, 4 * px));
  }
}
