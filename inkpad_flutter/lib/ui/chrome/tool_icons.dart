import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tool icons drawn on a 24×24 grid, for glyphs Material doesn't have
/// (cursor arrows, pen nib, anchor point, freehand blob, spiral, eraser…).
class ToolIcon extends StatelessWidget {
  final void Function(Canvas canvas, Paint stroke, Paint fill) draw;
  final double size;

  const ToolIcon(this.draw, {super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _IconPainter(draw, color)));
  }

  static void arrow(Canvas c, Paint stroke, Paint fill) => c.drawPath(_arrow(), fill);

  static void directSelect(Canvas c, Paint stroke, Paint fill) {
    c.save();
    c.translate(-1, 1);
    c.drawPath(_arrow(), fill);
    c.restore();
    _plus(c, stroke, const Offset(18, 5));
  }

  static Path _arrow() => Path()
    ..moveTo(5, 2.5)
    ..lineTo(5, 19.5)
    ..lineTo(9.3, 15.4)
    ..lineTo(12.2, 21.6)
    ..lineTo(14.6, 20.5)
    ..lineTo(11.8, 14.4)
    ..lineTo(17.6, 14.2)
    ..close();

  static void _plus(Canvas c, Paint stroke, Offset at) {
    final p = Paint.from(stroke)..strokeWidth = 2;
    c.drawLine(at - const Offset(3.5, 0), at + const Offset(3.5, 0), p);
    c.drawLine(at - const Offset(0, 3.5), at + const Offset(0, 3.5), p);
  }

  static void pen(Canvas c, Paint stroke, Paint fill) {
    final nib = Path()
      ..moveTo(12, 2)
      ..cubicTo(14.5, 6, 16.5, 9, 16.5, 12.5)
      ..lineTo(14.5, 17)
      ..lineTo(9.5, 17)
      ..lineTo(7.5, 12.5)
      ..cubicTo(7.5, 9, 9.5, 6, 12, 2)
      ..close();
    c.drawPath(nib, stroke);
    c.drawLine(const Offset(12, 4), const Offset(12, 10.5), stroke);
    c.drawCircle(const Offset(12, 11.6), 1.2, fill);
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(9.2, 18, 14.8, 22), const Radius.circular(1)), fill);
  }

  static void addAnchor(Canvas c, Paint stroke, Paint fill) {
    final pts = [const Offset(4.5, 19.5), const Offset(11, 11.5), const Offset(18.5, 5)];
    c.drawLine(pts[0], pts[1], stroke);
    c.drawLine(pts[1], pts[2], stroke);
    for (final p in pts) {
      c.drawRect(Rect.fromCenter(center: p, width: 4.2, height: 4.2), fill);
    }
    _plus(c, stroke, const Offset(18.5, 18.5));
  }

  static void blob(Canvas c, Paint stroke, Paint fill) {
    final p = Path()
      ..moveTo(6, 4.5)
      ..cubicTo(10, 2.5, 21, 5, 19.5, 11)
      ..cubicTo(18.5, 15, 14.5, 15, 13, 19)
      ..cubicTo(11.5, 22.5, 6, 21, 4.5, 16)
      ..cubicTo(3, 11, 2.5, 6.5, 6, 4.5)
      ..close();
    c.drawPath(p, Paint.from(fill)..color = fill.color.withValues(alpha: 0.18));
    c.drawPath(p, stroke);
  }

  static void spiral(Canvas c, Paint stroke, Paint fill) {
    final p = Path();
    const center = Offset(12, 12.5);
    for (var i = 0; i <= 120; i++) {
      final t = i / 120 * 3.2 * math.pi;
      final r = 1 + t * 0.95;
      final pt = center + Offset(math.cos(t), math.sin(t)) * r;
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    c.drawPath(p, stroke);
  }

  static void line(Canvas c, Paint stroke, Paint fill) =>
      c.drawLine(const Offset(4.5, 19.5), const Offset(19.5, 4.5), stroke);

  static void eraser(Canvas c, Paint stroke, Paint fill) {
    c.save();
    c.translate(12, 12);
    c.rotate(-math.pi / 4);
    final body = RRect.fromRectAndRadius(const Rect.fromLTRB(-9, -4.5, 9, 4.5), const Radius.circular(2));
    c.drawRRect(body, stroke);
    c.drawRect(const Rect.fromLTRB(-9, -4.5, -2.5, 4.5), Paint.from(fill)..color = fill.color.withValues(alpha: 0.85));
    c.restore();
  }

  static void scale(Canvas c, Paint stroke, Paint fill) {
    c.drawRect(const Rect.fromLTRB(4, 4, 20, 20), stroke);
    c.drawRect(const Rect.fromLTRB(4, 13, 11, 20), Paint.from(fill)..color = fill.color.withValues(alpha: 0.25));
    c.drawRect(const Rect.fromLTRB(4, 13, 11, 20), stroke);
    c.drawLine(const Offset(9, 15), const Offset(17.5, 6.5), stroke);
    c.drawPath(
      Path()
        ..moveTo(12.5, 6.5)
        ..lineTo(17.5, 6.5)
        ..lineTo(17.5, 11.5),
      stroke,
    );
  }

  static void rotate(Canvas c, Paint stroke, Paint fill) {
    c.drawArc(Rect.fromCircle(center: const Offset(12, 13), radius: 8), -math.pi / 2 + 0.5, 2 * math.pi - 0.9, false, stroke);
    c.drawPath(
      Path()
        ..moveTo(13.5, 2.5)
        ..lineTo(17.5, 5.5)
        ..lineTo(13.5, 8.5)
        ..close(),
      fill,
    );
    c.drawCircle(const Offset(12, 13), 1.3, fill);
  }

  static void text(Canvas c, Paint stroke, Paint fill) {
    final tp = TextPainter(
      text: TextSpan(
        text: 'T',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, fontFamily: 'serif', color: fill.color, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset((24 - tp.width) / 2, (24 - tp.height) / 2 + 1));
  }

  /// The soft circle for the shadow & opacity panel.
  static void shadow(Canvas c, Paint stroke, Paint fill) {
    // A soft gray halo with a white disc inside, like the screenshots.
    c.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTRB(2, 2, 22, 22), const Radius.circular(4)),
      Paint()
        ..color = fill.color.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    c.drawCircle(const Offset(12, 12), 5.5, Paint()..color = Colors.white);
    c.drawCircle(const Offset(12, 12), 2.2, Paint()..color = fill.color.withValues(alpha: 0.3));
  }
}

class _IconPainter extends CustomPainter {
  final void Function(Canvas, Paint, Paint) draw;
  final Color color;

  _IconPainter(this.draw, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final fill = Paint()..color = color;
    draw(canvas, stroke, fill);
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.color != color || old.draw != draw;
}

/// A line cap or join glyph for the stroke panel.
class StrokeGlyph extends StatelessWidget {
  final StrokeCap? cap;
  final StrokeJoin? join;
  final Color color;

  const StrokeGlyph({super.key, this.cap, this.join, required this.color});

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 48, height: 36, child: CustomPaint(painter: _GlyphPainter(cap, join, color)));
}

class _GlyphPainter extends CustomPainter {
  final StrokeCap? cap;
  final StrokeJoin? join;
  final Color color;

  _GlyphPainter(this.cap, this.join, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final thick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = color.withValues(alpha: 0.55);
    final thin = Paint()
      ..strokeWidth = 1.5
      ..color = Colors.black87;
    if (cap != null) {
      thick.strokeCap = cap!;
      canvas.drawLine(Offset(22, size.height / 2), Offset(size.width + 10, size.height / 2), thick);
      canvas.drawLine(Offset(4, size.height / 2), Offset(size.width, size.height / 2), thin);
      canvas.drawCircle(Offset(22, size.height / 2), 2.5, Paint()..color = Colors.black87);
    } else {
      thick
        ..strokeJoin = join!
        ..strokeCap = StrokeCap.butt;
      final path = Path()
        ..moveTo(size.width + 8, 14)
        ..lineTo(16, 14)
        ..lineTo(16, size.height + 8);
      canvas.drawPath(path, thick);
      canvas.drawPath(path, thin..style = PaintingStyle.stroke);
      canvas.drawCircle(const Offset(16, 14), 2.5, Paint()..color = Colors.black87);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.color != color;
}
