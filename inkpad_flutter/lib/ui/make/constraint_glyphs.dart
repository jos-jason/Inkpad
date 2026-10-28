import 'package:flutter/material.dart';

import '../../model/constraints.dart';
import '../../tools/tool.dart';

/// The constraint glyphs (∥, ⊥, ◎, …) drawn as lines, so they look the
/// same on every platform whatever its fonts.
void paintConstraintGlyph(Canvas canvas, SketchMode mode, Rect box, Color color) {
  final p = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = box.width / 9
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  Offset at(double x, double y) => Offset(box.left + x * box.width, box.top + y * box.height);
  void line(double x1, double y1, double x2, double y2) => canvas.drawLine(at(x1, y1), at(x2, y2), p);
  void poly(List<double> xy) {
    final path = Path()..moveTo(at(xy[0], xy[1]).dx, at(xy[0], xy[1]).dy);
    for (var i = 2; i < xy.length; i += 2) {
      path.lineTo(at(xy[i], xy[i + 1]).dx, at(xy[i], xy[i + 1]).dy);
    }
    canvas.drawPath(path, p);
  }

  switch (mode) {
    case SketchMode.dimension:
      line(0.1, 0.5, 0.9, 0.5);
      poly([0.28, 0.32, 0.1, 0.5, 0.28, 0.68]);
      poly([0.72, 0.32, 0.9, 0.5, 0.72, 0.68]);
    case SketchMode.coincident:
      canvas.drawCircle(at(0.5, 0.5), box.width * 0.28, p);
      canvas.drawCircle(at(0.5, 0.5), box.width * 0.08, p..style = PaintingStyle.fill);
    case SketchMode.horizontal:
      line(0.25, 0.18, 0.25, 0.82);
      line(0.75, 0.18, 0.75, 0.82);
      line(0.25, 0.5, 0.75, 0.5);
    case SketchMode.vertical:
      poly([0.22, 0.18, 0.5, 0.82, 0.78, 0.18]);
    case SketchMode.parallel:
      line(0.22, 0.82, 0.48, 0.18);
      line(0.52, 0.82, 0.78, 0.18);
    case SketchMode.perpendicular:
      line(0.5, 0.15, 0.5, 0.8);
      line(0.15, 0.8, 0.85, 0.8);
    case SketchMode.collinear:
      line(0.08, 0.5, 0.38, 0.5);
      line(0.62, 0.5, 0.92, 0.5);
      canvas.drawCircle(at(0.5, 0.5), box.width * 0.05, Paint()..color = color);
    case SketchMode.equal:
      line(0.2, 0.38, 0.8, 0.38);
      line(0.2, 0.62, 0.8, 0.62);
    case SketchMode.tangent:
      canvas.drawCircle(at(0.5, 0.6), box.width * 0.24, p);
      line(0.1, 0.36, 0.9, 0.36);
    case SketchMode.concentric:
      canvas.drawCircle(at(0.5, 0.5), box.width * 0.34, p);
      canvas.drawCircle(at(0.5, 0.5), box.width * 0.14, p);
    case SketchMode.midpoint:
      line(0.08, 0.72, 0.92, 0.72);
      poly([0.34, 0.72, 0.5, 0.36, 0.66, 0.72]);
    case SketchMode.symmetric:
      line(0.5, 0.12, 0.5, 0.88);
      poly([0.36, 0.3, 0.14, 0.5, 0.36, 0.7]);
      poly([0.64, 0.3, 0.86, 0.5, 0.64, 0.7]);
    case SketchMode.fix:
      // Lock: shackle and body.
      canvas.drawArc(Rect.fromLTRB(at(0.3, 0.12).dx, at(0.3, 0.12).dy, at(0.7, 0.52).dx, at(0.7, 0.52).dy), 3.1416, 3.1416, false, p);
      line(0.3, 0.32, 0.3, 0.45);
      line(0.7, 0.32, 0.7, 0.45);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromPoints(at(0.2, 0.45), at(0.8, 0.88)), Radius.circular(box.width * 0.08)),
        Paint()..color = color,
      );
  }
}

/// The glyph a constraint shows with.
SketchMode glyphFor(ConstraintType t) => switch (t) {
      ConstraintType.coincident || ConstraintType.pointOnLine || ConstraintType.pointOnCircle => SketchMode.coincident,
      ConstraintType.horizontal => SketchMode.horizontal,
      ConstraintType.vertical => SketchMode.vertical,
      ConstraintType.parallel => SketchMode.parallel,
      ConstraintType.perpendicular => SketchMode.perpendicular,
      ConstraintType.collinear => SketchMode.collinear,
      ConstraintType.equal => SketchMode.equal,
      ConstraintType.tangent => SketchMode.tangent,
      ConstraintType.concentric => SketchMode.concentric,
      ConstraintType.midpoint => SketchMode.midpoint,
      ConstraintType.symmetric => SketchMode.symmetric,
      ConstraintType.fix => SketchMode.fix,
      _ => SketchMode.dimension,
    };

/// A constraint glyph as a widget (for the tool bar).
class ConstraintGlyph extends StatelessWidget {
  final SketchMode mode;
  final Color color;
  final double size;

  const ConstraintGlyph(this.mode, {super.key, required this.color, this.size = 20});

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _GlyphPainter(mode, color));
}

class _GlyphPainter extends CustomPainter {
  final SketchMode mode;
  final Color color;

  _GlyphPainter(this.mode, this.color);

  @override
  void paint(Canvas canvas, Size size) => paintConstraintGlyph(canvas, mode, Offset.zero & size, color);

  @override
  bool shouldRepaint(_GlyphPainter old) => old.mode != mode || old.color != color;
}
