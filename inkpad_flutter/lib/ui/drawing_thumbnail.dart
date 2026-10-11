import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/drawing.dart';
import '../model/image.dart';
import '../text/font_library.dart';

/// Renders a whole drawing scaled to fit, on a white page.
class DrawingThumbnail extends StatelessWidget {
  final InkDrawing drawing;

  const DrawingThumbnail({super.key, required this.drawing});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: drawing.width / drawing.height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
        ),
        child: ClipRect(
          child: ValueListenableBuilder(
            valueListenable: ImageData.decodes,
            builder: (context, _, _) => ListenableBuilder(
              listenable: FontLibrary.instance,
              builder: (context, _) => CustomPaint(painter: _ThumbnailPainter(drawing)),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThumbnailPainter extends CustomPainter {
  final InkDrawing drawing;

  _ThumbnailPainter(this.drawing);

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width / drawing.width, size.height / drawing.height);
    canvas.scale(s);
    drawing.render(canvas, drawing.bounds);
  }

  // Drawings are edited in place, so always repaint when rebuilt.
  @override
  bool shouldRepaint(_ThumbnailPainter old) => true;
}
