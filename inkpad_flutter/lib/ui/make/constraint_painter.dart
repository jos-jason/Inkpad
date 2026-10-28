import 'package:flutter/material.dart';

import '../../controller/constraint_marks.dart';
import '../../controller/drawing_controller.dart';
import '../../model/constraints.dart';
import '../../model/element.dart';
import '../../tools/tool.dart';
import 'constraint_glyphs.dart';

/// Draws sketch constraints on the canvas (in drawing coordinates):
/// dimensions always; with the Constraints tool, each constraint's glyph,
/// and constrained shapes in green when they can't move or blue while
/// they still can.
class ConstraintPainter {
  static const dimensionColor = Color(0xFF1565C0);
  static const referenceColor = Color(0xFF78909C);
  static const selectedColor = Color(0xFFFF8F00);
  static const conflictColor = Color(0xFFD32F2F);
  static const fixedColor = Color(0xFF2E7D32);
  static const freeColor = Color(0xFF1E88E5);

  /// The labels' font (null: the platform's).
  static String? fontFamily;

  static void paint(Canvas canvas, DrawingController c, double scale) {
    if (c.drawing.constraints.isEmpty) return;
    final tool = c.tool is ConstraintTool;
    final px = 1 / scale;

    if (tool) {
      final info = c.sketchInfo;
      final ids = {for (final k in c.drawing.constraints) ...k.elements};
      for (final id in ids) {
        final e = c.elementWithId(id);
        if (e is! InkStylable) continue;
        canvas.drawPath(
          e.toFlutterPath(),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * px
            ..color = (info?.fixed.contains(id) ?? false) ? fixedColor : freeColor,
        );
      }
    }

    for (final m in layoutConstraints(c, scale, glyphs: tool)) {
      final k = m.constraint;
      final selected = identical(k, c.selectedConstraint);
      final color = selected
          ? selectedColor
          : c.sketchConflict
              ? conflictColor
              : m.isDimension
                  ? (k.reference ? referenceColor : dimensionColor)
                  : const Color(0xFF37474F);
      final line = Paint()
        ..color = color
        ..strokeWidth = 1 * px;
      for (final (a, b) in m.lines) {
        canvas.drawLine(a, b, line);
      }
      if (m.isDimension && m.lines.isNotEmpty && k.type != ConstraintType.angle) {
        // Ticks across the dimension line's ends.
        final (a, b) = m.lines.first;
        final d = b - a;
        if (d.distance > 0) {
          final n = Offset(-d.dy + d.dx, d.dx + d.dy) / d.distance * (4 * px);
          canvas.drawLine(b - n, b + n, line);
          if (k.type != ConstraintType.radius) canvas.drawLine(a - n, a + n, line);
        }
      }
      _label(canvas, m, color, px, badge: !m.isDimension);
    }
  }

  static void _label(Canvas canvas, ConstraintMark m, Color color, double px, {required bool badge}) {
    canvas.save();
    canvas.translate(m.at.dx, m.at.dy);
    canvas.scale(px);
    if (badge) {
      // A glyph in a small white badge.
      const box = Rect.fromLTWH(-8, -8, 16, 16);
      final r = RRect.fromRectAndRadius(box, const Radius.circular(4));
      canvas.drawRRect(r, Paint()..color = Colors.white);
      canvas.drawRRect(
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke,
      );
      paintConstraintGlyph(canvas, glyphFor(m.constraint.type), box.deflate(2.5), color);
    } else {
      final tp = TextPainter(
        text: TextSpan(text: m.text, style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, fontFamily: fontFamily)),
        textDirection: TextDirection.ltr,
      )..layout();
      final box = Rect.fromCenter(center: Offset.zero, width: tp.width + 8, height: tp.height + 2);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)), Paint()..color = color);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    }
    canvas.restore();
  }
}
