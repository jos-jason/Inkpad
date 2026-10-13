import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../drawing_canvas.dart';
import 'length_field.dart';

/// Make mode: the selection's overall width and height drawn as dimension
/// lines beside it. Tap a number to type a new size. A single live shape
/// is measured along its own sides (even when turned); anything else by its
/// bounding box.
class DimensionOverlay extends StatefulWidget {
  final DrawingController controller;
  final CanvasView view;

  /// Where the canvas's top-left corner sits in this overlay.
  final Offset origin;

  const DimensionOverlay({super.key, required this.controller, required this.view, required this.origin});

  @override
  State<DimensionOverlay> createState() => _DimensionOverlayState();
}

class _DimensionOverlayState extends State<DimensionOverlay> {
  /// Which dimension is being typed: 'w' or 'h'.
  String? _editing;

  DrawingController get c => widget.controller;

  /// Four corners of what's measured (top-left, top-right, bottom-right,
  /// bottom-left), in screen space.
  List<Offset>? _corners() {
    final live = c.singleLiveShape?.live;
    final List<Offset> doc;
    if (live != null && live.height > 0) {
      doc = live.corners;
    } else {
      final b = c.selectionBounds;
      if (b == null) return null;
      doc = [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft];
    }
    return [for (final p in doc) widget.view.toScreen(p) + widget.origin];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, widget.view]),
      builder: (context, _) {
        final m = c.measure;
        final corners = _corners();
        if (m == null || corners == null || c.editingText != null) return const SizedBox.shrink();
        final lengths = c.drawing.lengths;
        final color = Theme.of(context).colorScheme.primary;

        // The width runs along the top edge, the height along the left,
        // each pushed outwards by a gap.
        const gap = 22.0;
        Offset outward(Offset a, Offset b, Offset inside) {
          final d = b - a;
          var n = Offset(d.dy, -d.dx) / (d.distance == 0 ? 1 : d.distance);
          if (((a + b) / 2 + n - inside).distance < ((a + b) / 2 - n - inside).distance) n = -n;
          return n * gap;
        }

        final center = corners.reduce((a, b) => a + b) / 4;
        final topShift = outward(corners[0], corners[1], center);
        final leftShift = outward(corners[3], corners[0], center);
        final wLine = (corners[0] + topShift, corners[1] + topShift);
        final hLine = (corners[3] + leftShift, corners[0] + leftShift);

        Widget label(String which, (Offset, Offset) line, double value) {
          final mid = (line.$1 + line.$2) / 2;
          final editing = _editing == which;
          return Positioned(
            left: mid.dx - (editing ? 70 : 50),
            top: mid.dy - 16,
            width: editing ? 140 : 100,
            height: 32,
            child: Center(
              child: editing
                  ? Material(
                      elevation: 3,
                      borderRadius: BorderRadius.circular(8),
                      child: LengthField(
                        key: ValueKey(which),
                        value: value,
                        lengths: lengths,
                        width: 140,
                        onChanged: (v) {
                          setState(() => _editing = null);
                          if (which == 'w') {
                            c.resizeSelection(width: v);
                          } else {
                            c.resizeSelection(height: v);
                          }
                        },
                      ),
                    )
                  : Tooltip(
                      message: which == 'w' ? 'Width: tap to type' : 'Height: tap to type',
                      child: Material(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => setState(() => _editing = which),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            child: Text(
                              lengths.format(value),
                              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          );
        }

        final isLine = c.singleLiveShape?.live?.height == 0;
        return Stack(children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _DimensionLines([wLine, if (!isLine) hLine], corners, color)),
            ),
          ),
          if (_editing != 'w') label('w', wLine, m.width),
          if (!isLine && _editing != 'h') label('h', hLine, m.height),
          // Typing ends when clicking elsewhere.
          if (_editing != null)
            Positioned.fill(
              child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: () => setState(() => _editing = null)),
            ),
          if (_editing != null) label(_editing!, _editing == 'w' ? wLine : hLine, _editing == 'w' ? m.width : m.height),
        ]);
      },
    );
  }
}

class _DimensionLines extends CustomPainter {
  final List<(Offset, Offset)> lines;
  final List<Offset> corners;
  final Color color;

  _DimensionLines(this.lines, this.corners, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    final ext = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (final (a, b) in lines) {
      canvas.drawLine(a, b, p);
      // Ticks at the ends, across the line.
      final d = b - a;
      if (d.distance < 1) continue;
      final n = Offset(-d.dy, d.dx) / d.distance * 5;
      canvas.drawLine(a - n, a + n, p);
      canvas.drawLine(b - n, b + n, p);
      // Extension lines back to the shape.
      for (final end in [a, b]) {
        final nearest = corners.reduce((x, y) => (x - end).distance < (y - end).distance ? x : y);
        canvas.drawLine(nearest, end + (end - nearest) / math.max((end - nearest).distance, 1) * 4, ext);
      }
    }
  }

  @override
  bool shouldRepaint(_DimensionLines old) => true;
}
