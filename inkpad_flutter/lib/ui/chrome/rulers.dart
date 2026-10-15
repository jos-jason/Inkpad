import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/drawing.dart';
import '../drawing_canvas.dart';

/// Canvas rulers in the drawing's units, measured from the page's top-left.
/// Ported in spirit from Inkpad's WDRuler.
class Ruler extends StatelessWidget {
  static const thickness = 22.0;

  final CanvasView view;
  final InkDrawing drawing;
  final Axis axis;

  const Ruler({super.key, required this.view, required this.drawing, required this.axis});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: view,
      builder: (context, _) => CustomPaint(
        size: axis == Axis.horizontal ? const Size(double.infinity, thickness) : const Size(thickness, double.infinity),
        painter: _RulerPainter(
          scale: view.scale,
          origin: axis == Axis.horizontal ? view.offset.dx : view.offset.dy,
          unitSize: InkDrawing.unitSizes[drawing.units] ?? 72,
          inches: drawing.units == 'in',
          axis: axis,
          background: scheme.surfaceContainerHighest,
          ink: scheme.onSurface.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  final double scale, origin, unitSize;
  final bool inches;
  final Axis axis;
  final Color background, ink;

  _RulerPainter({
    required this.scale,
    required this.origin,
    required this.unitSize,
    required this.inches,
    required this.axis,
    required this.background,
    required this.ink,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final horizontal = axis == Axis.horizontal;
    final length = horizontal ? size.width : size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final edge = Paint()
      ..color = ink
      ..strokeWidth = 1;
    horizontal
        ? canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), edge)
        : canvas.drawLine(Offset(size.width - 0.5, 0), Offset(size.width - 0.5, size.height), edge);

    // Major ticks: the smallest 1/2/5×10ⁿ units at least 60px apart.
    final pxPerUnit = unitSize * scale;
    var major = 1.0;
    final magnitude = math.pow(10, (math.log(60 / pxPerUnit) / math.ln10).floor()).toDouble();
    for (final m in [1.0, 2.0, 5.0, 10.0]) {
      major = m * magnitude;
      if (major * pxPerUnit >= 60) break;
    }
    // Minor ticks: eighths for inches, tenths otherwise, thinned out when crowded.
    var divisions = inches && major <= 1 ? 8 : 10;
    while (divisions > 1 && major * pxPerUnit / divisions < 6) {
      divisions = divisions == 8 ? 4 : (divisions == 10 ? 5 : divisions ~/ 2);
    }

    final step = major * pxPerUnit / divisions;
    final first = ((-origin) / step).floor();
    final last = ((length - origin) / step).ceil();
    final label = TextPainter(textDirection: TextDirection.ltr);
    for (var i = first; i <= last; i++) {
      final pos = origin + i * step;
      final isMajor = i % divisions == 0;
      final isHalf = !isMajor && divisions.isEven && i % (divisions ~/ 2) == 0;
      final tick = isMajor ? 9.0 : (isHalf ? 6.0 : 3.5);
      if (horizontal) {
        canvas.drawLine(Offset(pos, size.height), Offset(pos, size.height - tick), edge);
      } else {
        canvas.drawLine(Offset(size.width, pos), Offset(size.width - tick, pos), edge);
      }
      if (isMajor) {
        final value = i ~/ divisions * major;
        label.text = TextSpan(
          text: value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1),
          style: TextStyle(fontSize: 10.5, color: ink),
        );
        label.layout();
        if (horizontal) {
          label.paint(canvas, Offset(pos + 3, 1));
        } else {
          canvas.save();
          canvas.translate(2, pos + 3);
          label.paint(canvas, Offset.zero);
          canvas.restore();
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.scale != scale || old.origin != origin || old.unitSize != unitSize || old.background != background;
}
