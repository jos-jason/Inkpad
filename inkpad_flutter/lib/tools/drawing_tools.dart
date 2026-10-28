import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../geometry/pathfinder.dart';
import '../model/element.dart';
import '../model/style.dart';
import 'tool.dart';

/// Draws by hand; the stroke is smoothed into bezier curves when you lift.
/// Ported from WDFreehandTool:
///  * Freehand ([closeShape]) makes a closed, filled shape;
///  * Brush makes an open line in the current stroke (closing itself if
///    the ends meet).
class FreehandTool extends Tool {
  final bool closeShape;

  FreehandTool({required this.closeShape});

  @override
  String get name => closeShape ? 'Freehand' : 'Brush';

  /// Smoothing, in screen pixels (Inkpad's kMaxError); closed shapes are
  /// relaxed five times further, as in Inkpad.
  static const maxError = 10.0;

  final List<Offset> points = [];
  double _viewScale = 1;

  @override
  void begin(DrawingController c, ToolEvent e) {
    c.selectNone();
    points
      ..clear()
      ..add(e.point);
    _viewScale = e.viewScale;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    if ((e.point - points.last).distance * _viewScale < 1.5) return;
    points.add(e.point);
    c.changed();
  }

  /// The stroke used for brush lines: the current stroke, or (with no
  /// stroke set) a 2pt line in the fill color so the line is visible.
  StrokeStyle brushStroke(DrawingController c) =>
      c.strokeStyle ?? StrokeStyle(width: 2, color: c.fillPaint?.representativeColor ?? InkColor.black);

  @override
  void end(DrawingController c, ToolEvent e) {
    final tolerance = maxError * (closeShape ? 5 : 1) / _viewScale;
    final path = points.length > 1 ? Pathfinder.smooth(points, tolerance: tolerance, close: closeShape) : null;
    points.clear();
    if (path == null) {
      c.changed();
      return;
    }
    c.checkpoint();
    if (closeShape) {
      c.styledPath(path);
    } else {
      path
        ..stroke = brushStroke(c)
        ..opacity = c.defaultOpacity
        ..shadow = c.defaultShadow
        ..blendMode = c.defaultBlendMode;
    }
    c.addElement(path);
    // Select it without adopting its style: a brush line has no fill, and
    // that shouldn't clear the current fill for the next shape.
    c.selection
      ..clear()
      ..add(path);
    c.changed();
  }

  @override
  void cancel(DrawingController c) {
    points.clear();
    c.changed();
  }

  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    if (points.length < 2) return;
    final preview = Path()..addPolygon(points, closeShape);
    if (closeShape && c.fillPaint != null) {
      canvas.drawPath(preview, Paint()..color = c.fillPaint!.representativeColor.toColor(0.5));
    }
    final s = closeShape ? c.strokeStyle : brushStroke(c);
    canvas.drawPath(
      preview,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s?.width ?? 1 / viewScale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = (s?.color ?? InkColor.black).toColor(),
    );
  }
}

/// Erases along a drawn stroke. Ported from WDEraserTool: works on the
/// selection, or on everything in visible, unlocked layers when nothing is
/// selected; closed shapes lose the area, open lines are cut into pieces.
class EraserTool extends Tool {
  @override
  String get name => 'Eraser';

  /// Eraser width in points (Inkpad: 1–100, default 20).
  double size = 20;

  /// Smoothing in screen pixels (Inkpad's kMaxError for the eraser).
  static const maxError = 5.0;

  final List<Offset> points = [];
  double _viewScale = 1;

  @override
  void begin(DrawingController c, ToolEvent e) {
    points
      ..clear()
      ..add(e.point);
    _viewScale = e.viewScale;
  }

  @override
  void move(DrawingController c, ToolEvent e) {
    if ((e.point - points.last).distance * _viewScale < 3) return;
    points.add(e.point);
    c.changed();
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    final InkStylable? eraser;
    if (points.length == 1) {
      // A tap erases a dot.
      eraser = InkPath.oval(Rect.fromCircle(center: points.single, radius: size / 2));
    } else {
      final line = Pathfinder.smooth(points, tolerance: maxError / _viewScale);
      line?.stroke = StrokeStyle(width: size, cap: LineCap.round, join: LineJoin.round);
      eraser = line == null ? null : Pathfinder.outlineStroke(line);
    }
    points.clear();
    if (eraser != null) c.erase(eraser);
    c.changed();
  }

  @override
  void cancel(DrawingController c) {
    points.clear();
    c.changed();
  }

  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xD9E6E6E6);
    if (points.length == 1) {
      canvas.drawCircle(points.single, size / 2, paint..style = PaintingStyle.fill);
    } else {
      canvas.drawPath(Path()..addPolygon(points, false), paint);
    }
  }
}

/// Cuts paths. Ported from WDScissorTool: tap a path's line to cut it
/// there, or tap a point to cut at the point. An open path splits in two
/// (its end points can't be cut); a closed path opens up.
class ScissorsTool extends Tool {
  @override
  String get name => 'Scissors';

  @override
  void begin(DrawingController c, ToolEvent e) {
    final tol = e.slop();
    for (final path in c.pathOwners().keys.toList().reversed) {
      final i = path.anchorIndexAt(e.point, tol);
      if (i != null) {
        if (path.closed || (i > 0 && i < path.nodes.length - 1)) {
          c.splitPath(path, i);
          return;
        }
        continue; // an open path's end: nothing to cut
      }
      final hit = path.edgeHit(e.point, tol + (path.stroke?.width ?? 0) / 2);
      if (hit != null) {
        c.splitPathAt(path, hit.$1, hit.$2);
        return;
      }
    }
  }
}

/// Picks up a style. Ported from WDEyedropperTool: drag over the drawing
/// to preview the color under the pointer; lift to copy that element's
/// fill, stroke and opacity onto the selection and into the current style.
/// Over a photo it picks the pixel color.
class EyedropperTool extends Tool {
  @override
  String get name => 'Eyedropper';

  InkElement? _picked;
  InkColor? _sampled;
  Offset? _point;

  @override
  void begin(DrawingController c, ToolEvent e) => move(c, e);

  @override
  void move(DrawingController c, ToolEvent e) {
    _point = e.point;
    _picked = _elementAt(c, e.point, e.slop(4));
    _sampled = null;
    final picked = _picked;
    if (picked is InkImage) {
      picked.data.loadPixels();
      final px = picked.data.pixelAt(picked.placement.inverted().apply(e.point));
      if (px != null) _sampled = InkColor(px.$1, px.$2, px.$3, px.$4);
    }
    c.changed();
  }

  /// The innermost element under [p] (looking inside groups).
  InkElement? _elementAt(DrawingController c, Offset p, double tol) {
    InkElement? within(Iterable<InkElement> elements) {
      for (final e in elements.toList().reversed) {
        if (!e.hitTest(p, tol)) continue;
        if (e is InkGroup) return within(e.elements) ?? e;
        return e;
      }
      return null;
    }

    for (final l in c.drawing.layers.reversed) {
      if (!l.visible) continue;
      final hit = within(l.elements);
      if (hit != null) return hit;
    }
    return null;
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    final picked = _picked;
    if (picked != null) c.pickStyle(picked, sampled: _sampled);
    _picked = null;
    _point = null;
    c.changed();
  }

  @override
  void cancel(DrawingController c) {
    _picked = null;
    _point = null;
  }

  /// A loupe above the pointer showing what would be picked.
  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    final p = _point;
    if (p == null) return;
    final px = 1 / viewScale;
    final center = p - Offset(0, 44 * px);
    final picked = _picked;
    final color = _sampled ??
        (picked is InkStylable ? (picked.fill ?? picked.stroke?.color)?.representativeColor : null);
    canvas.drawCircle(center, 22 * px, Paint()..color = const Color(0x33000000));
    canvas.drawCircle(center, 20 * px, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(center, 15 * px, Paint()..color = color?.toColor() ?? const Color(0x00000000));
    if (color == null) {
      canvas.drawLine(center + Offset(-10 * px, 10 * px), center + Offset(10 * px, -10 * px), Paint()..color = const Color(0xFFFF3B30)..strokeWidth = 2 * px);
    }
  }
}
