import 'dart:ui';

import '../controller/constraint_marks.dart';
import '../controller/drawing_controller.dart';
import '../model/constraints.dart';
import '../model/element.dart';
import 'tool.dart';

/// What the Constraints tool makes when items are picked.
enum SketchMode {
  dimension('Dimension', '↔', 'Pick a line or circle, or two items, to dimension. With one line, click empty space to measure its length.'),
  coincident('Coincident', '×', 'Pick two points (or a point and a line or circle) to join.'),
  horizontal('Horizontal', 'H', 'Pick a line, or two points, to make level.'),
  vertical('Vertical', 'V', 'Pick a line, or two points, to make upright.'),
  parallel('Parallel', '∥', 'Pick two lines.'),
  perpendicular('Perpendicular', '⊥', 'Pick two lines.'),
  collinear('Collinear', '⋯', 'Pick two lines to put on one line.'),
  equal('Equal', '=', 'Pick two lines (equal length) or two circles (equal size).'),
  tangent('Tangent', 'T', 'Pick a line and a circle, or two circles.'),
  concentric('Concentric', '◎', 'Pick two circles (or a circle and a point).'),
  midpoint('Midpoint', '△', 'Pick a point and a line: the point goes to its middle.'),
  symmetric('Symmetric', '⌯', 'Pick two points, then the line they mirror about.'),
  fix('Fix', '⚲', 'Pick a point, line or circle to hold where it is.');

  final String label, glyph, prompt;

  const SketchMode(this.label, this.glyph, this.prompt);
}

/// Make mode: constrains shapes' points, edges and circles like a CAD
/// sketch (coincident, parallel, tangent, dimensions, …). Pick a kind of
/// constraint, then the items. Click a constraint's mark to pick it
/// (Delete removes it); double-click a dimension to change it.
class ConstraintTool extends Tool {
  @override
  String get name => 'Constraints';

  SketchMode mode = SketchMode.dimension;

  /// Items picked so far.
  final List<GeoRef> picks = [];

  void setMode(DrawingController c, SketchMode m) {
    mode = m;
    picks.clear();
    c.changed();
  }

  /// The constraint mark under [p], if any.
  SketchConstraint? markAt(DrawingController c, Offset p, double viewScale) {
    final slop = 12 / viewScale;
    SketchConstraint? best;
    var bestD = slop;
    for (final m in layoutConstraints(c, viewScale)) {
      final d = (m.at - p).distance;
      if (d < bestD) {
        bestD = d;
        best = m.constraint;
      }
    }
    return best;
  }

  /// The point, line or circle under [p]: points first, then circles, then
  /// lines; topmost shapes first.
  GeoRef? pick(DrawingController c, Offset p, double tolerance) {
    final shapes = <InkPath>[];
    for (final l in c.drawing.layers) {
      if (!l.editable) continue;
      for (final e in l.elements) {
        for (final d in e.selfAndDescendants) {
          if (d is InkPath) shapes.add(d);
        }
      }
    }
    GeoRef? best;
    var bestD = tolerance;
    var bestRank = 3;
    for (final s in shapes.reversed) {
      final g = SketchGeometry.of(s);
      void consider(GeoKind kind, int i, double d, int rank) {
        if (d > tolerance) return;
        if (rank < bestRank || rank == bestRank && d < bestD) {
          best = GeoRef(s.ensureId, kind, i);
          bestD = d;
          bestRank = rank;
        }
      }

      for (final (i, q) in g.points) {
        consider(GeoKind.point, i, (q - p).distance, 0);
      }
      for (final (i, cc, r) in g.circles) {
        consider(GeoKind.circle, i, ((p - cc).distance - r).abs(), 1);
      }
      for (final (i, a, b) in g.lines) {
        consider(GeoKind.line, i, _toSegment(p, a, b), 2);
      }
    }
    return best;
  }

  static double _toSegment(Offset p, Offset a, Offset b) {
    final d = b - a;
    final len2 = d.distanceSquared;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * d.dx + (p - a).dy * d.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + d * t)).distance;
  }

  @override
  void end(DrawingController c, ToolEvent e) {
    final mark = markAt(c, e.point, e.viewScale);
    if (mark != null && picks.isEmpty) {
      c.selectedConstraint = mark;
      if (e.count >= 2 && mark.type.isDimension) {
        c.dimensionEdit.value = mark;
      } else {
        c.showHint('${mark.type.label}${mark.reference ? ' (reference)' : ''}: Delete removes it${mark.type.isDimension ? '; double-click to change it' : ''}.');
      }
      c.changed();
      return;
    }
    c.selectedConstraint = null;
    final hit = pick(c, e.point, e.slop(10));
    if (hit == null) {
      // A single line's length.
      if (mode == SketchMode.dimension && picks.length == 1 && picks.first.kind == GeoKind.line) {
        c.dimensionRequest.value = List.of(picks);
      }
      picks.clear();
      c.changed();
      return;
    }
    if (picks.contains(hit)) {
      picks.remove(hit);
      c.changed();
      return;
    }
    picks.add(hit);
    _advance(c);
    c.changed();
  }

  /// Makes the constraint once enough items are picked.
  void _advance(DrawingController c) {
    final kinds = [for (final p in picks) p.kind];
    bool are(List<GeoKind> k) => kinds.length == k.length && Iterable.generate(k.length).every((i) => kinds[i] == k[i]);
    bool either(GeoKind a, GeoKind b) => are([a, b]) || are([b, a]);
    final isLine = kinds.last == GeoKind.line, n = picks.length;

    void make(ConstraintType t) {
      final refs = List.of(picks);
      picks.clear();
      if (c.constrain(t, refs) == null) c.showHint('${t.label} added.');
    }

    void wrong(String message) {
      picks.clear();
      c.showHint(message);
    }

    switch (mode) {
      case SketchMode.dimension:
        if (n == 1 && kinds.first == GeoKind.circle || n == 2) {
          c.dimensionRequest.value = List.of(picks);
          picks.clear();
        }
      case SketchMode.coincident:
        if (n < 2) return;
        if (are([GeoKind.point, GeoKind.point])) return make(ConstraintType.coincident);
        if (either(GeoKind.point, GeoKind.line)) return make(ConstraintType.pointOnLine);
        if (either(GeoKind.point, GeoKind.circle)) return make(ConstraintType.pointOnCircle);
        if (are([GeoKind.circle, GeoKind.circle])) return make(ConstraintType.concentric);
        if (are([GeoKind.line, GeoKind.line])) return make(ConstraintType.collinear);
      case SketchMode.horizontal || SketchMode.vertical:
        final t = mode == SketchMode.horizontal ? ConstraintType.horizontal : ConstraintType.vertical;
        if (n == 1 && isLine) return make(t);
        if (n == 2) {
          if (kinds.contains(GeoKind.line)) return wrong('Pick a line, or two points.');
          return make(t);
        }
      case SketchMode.parallel || SketchMode.perpendicular || SketchMode.collinear:
        if (!isLine) return wrong('Pick two lines.');
        if (n == 2) {
          return make(switch (mode) {
            SketchMode.parallel => ConstraintType.parallel,
            SketchMode.perpendicular => ConstraintType.perpendicular,
            _ => ConstraintType.collinear,
          });
        }
      case SketchMode.equal:
        if (kinds.first == GeoKind.point) return wrong(mode.prompt);
        if (n == 2) {
          if (kinds[0] != kinds[1]) return wrong(mode.prompt);
          return make(ConstraintType.equal);
        }
      case SketchMode.tangent:
        if (kinds.contains(GeoKind.point)) return wrong(mode.prompt);
        if (n == 2) {
          if (are([GeoKind.line, GeoKind.line])) return wrong(mode.prompt);
          return make(ConstraintType.tangent);
        }
      case SketchMode.concentric:
        if (isLine) return wrong(mode.prompt);
        if (n == 2) {
          if (!kinds.contains(GeoKind.circle)) return wrong(mode.prompt);
          return make(ConstraintType.concentric);
        }
      case SketchMode.midpoint:
        if (n == 2) {
          if (!either(GeoKind.point, GeoKind.line)) return wrong(mode.prompt);
          return make(ConstraintType.midpoint);
        }
      case SketchMode.symmetric:
        if (n < 3 && isLine) return wrong(mode.prompt);
        if (n == 3) {
          if (!are([GeoKind.point, GeoKind.point, GeoKind.line])) return wrong(mode.prompt);
          return make(ConstraintType.symmetric);
        }
      case SketchMode.fix:
        return make(ConstraintType.fix);
    }
  }

  @override
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {
    final paint = Paint()
      ..color = const Color(0xFFFF8F00)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 / viewScale;
    for (final r in picks) {
      final g = c.geometryOf(r.element);
      switch (r.kind) {
        case GeoKind.point:
          final p = g.point(r.index);
          if (p != null) canvas.drawCircle(p, 5 / viewScale, paint);
        case GeoKind.line:
          final l = g.line(r.index);
          if (l != null) canvas.drawLine(l.$1, l.$2, paint);
        case GeoKind.circle:
          final ci = g.circle(r.index);
          if (ci != null) canvas.drawCircle(ci.$1, ci.$2, paint);
      }
    }
  }
}
