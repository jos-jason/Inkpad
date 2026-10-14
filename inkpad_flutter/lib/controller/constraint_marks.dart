import 'dart:math' as math;
import 'dart:ui';

import '../model/constraints.dart';
import 'drawing_controller.dart';

/// Where a constraint is shown on the canvas: a glyph (H, ∥, …) or a
/// dimension's value at [at], with a dimension's lines (all in drawing
/// coordinates).
class ConstraintMark {
  final SketchConstraint constraint;
  final Offset at;
  final String text;
  final List<(Offset, Offset)> lines;

  const ConstraintMark(this.constraint, this.at, this.text, [this.lines = const []]);

  bool get isDimension => constraint.type.isDimension;
}

/// Lays out every constraint's marks for a view at [viewScale] (screen
/// pixels per point): dimensions always, glyphs when [glyphs].
List<ConstraintMark> layoutConstraints(DrawingController c, double viewScale, {bool glyphs = true}) {
  final px = 1 / viewScale; // one screen pixel, in points
  final geometry = <String, SketchGeometry>{};
  SketchGeometry g(String id) => geometry.putIfAbsent(id, () => c.geometryOf(id));
  Offset? centreOf(String id) {
    final e = c.elementWithId(id);
    return e?.bounds.center;
  }

  final marks = <ConstraintMark>[];
  final used = <(int, int), int>{}; // glyphs already near a place
  final lengths = c.drawing.lengths;

  // A glyph near [r], pushed away from its shape and from other glyphs.
  void glyph(SketchConstraint k, GeoRef r) {
    final geo = g(r.element);
    var at = geo.anchor(r);
    if (at == null) return;
    var out = const Offset(1, -1) / math.sqrt2;
    if (r.kind == GeoKind.line) {
      final (a, b) = geo.line(r.index)!;
      final d = b - a;
      if (d.distance > 0) out = Offset(d.dy, -d.dx) / d.distance;
      // Inside the shape, clear of dimensions (which go outside).
      final centre = centreOf(r.element);
      if (centre != null && ((at + out) - centre).distance > ((at - out) - centre).distance) out = -out;
    } else if (r.kind == GeoKind.circle) {
      final (cc, rad) = geo.circle(r.index)!;
      at = cc + const Offset(1, -1) / math.sqrt2 * rad;
    }
    at = at + out * (14 * px);
    final key = ((at.dx * viewScale / 18).round(), (at.dy * viewScale / 18).round());
    final n = used[key] = (used[key] ?? -1) + 1;
    marks.add(ConstraintMark(k, at + Offset(n * 18 * px, 0), k.type == ConstraintType.fix ? '⚲' : k.type.glyph));
  }

  for (final k in c.drawing.constraints) {
    if (!k.type.isDimension) {
      if (!glyphs) continue;
      // Symmetry shows on its line; others on each item.
      final refs = k.type == ConstraintType.symmetric ? [k.refs.last] : k.refs;
      for (final r in refs) {
        glyph(k, r);
      }
      continue;
    }
    final m = _dimension(k, g, centreOf, px, lengths.format);
    if (m != null) marks.add(m);
  }
  return marks;
}

ConstraintMark? _dimension(
  SketchConstraint k,
  SketchGeometry Function(String) g,
  Offset? Function(String) centreOf,
  double px,
  String Function(double) format,
) {
  final refs = k.refs;
  final gap = 22 * px, over = 5 * px;
  String text(String value) {
    final t = '${k.formula != null ? 'ƒ ' : ''}$value';
    return k.reference ? '($t)' : t;
  }

  Offset? p(GeoRef r) => g(r.element).anchor(r);
  (Offset, Offset)? l(GeoRef r) => g(r.element).line(r.index);

  switch (k.type) {
    case ConstraintType.radius || ConstraintType.diameter:
      final circle = g(refs.first.element).circle(refs.first.index);
      if (circle == null) return null;
      final (cc, rad) = circle;
      const d = Offset(0.7071, -0.7071);
      final from = k.type == ConstraintType.radius ? cc : cc - d * rad;
      final to = cc + d * (rad + gap);
      return ConstraintMark(k, to + d * (10 * px), text('${k.type == ConstraintType.radius ? 'R' : 'Ø'}${format(k.value)}'), [(from, to)]);
    case ConstraintType.angle:
      final l1 = l(refs[0]), l2 = l(refs[1]);
      if (l1 == null || l2 == null) return null;
      final d1 = l1.$2 - l1.$1, d2 = l2.$2 - l2.$1;
      final cross = d1.dx * d2.dy - d1.dy * d2.dx;
      Offset corner;
      if (cross.abs() < 1e-9) {
        corner = (l1.$1 + l1.$2) / 2;
      } else {
        final t = ((l2.$1 - l1.$1).dx * d2.dy - (l2.$1 - l1.$1).dy * d2.dx) / cross;
        corner = l1.$1 + d1 * t;
      }
      final a1 = math.atan2(d1.dy, d1.dx), sweep = math.atan2(cross, d1.dx * d2.dx + d1.dy * d2.dy);
      final rad = 36 * px;
      final arc = <(Offset, Offset)>[];
      Offset on(double a) => corner + Offset(math.cos(a), math.sin(a)) * rad;
      for (var i = 0; i < 12; i++) {
        arc.add((on(a1 + sweep * i / 12), on(a1 + sweep * (i + 1) / 12)));
      }
      final mid = a1 + sweep / 2;
      var v = k.value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
      if (v == '-0') v = '0';
      return ConstraintMark(k, corner + Offset(math.cos(mid), math.sin(mid)) * (rad + 14 * px), text('$v°'), arc);
    case ConstraintType.horizontalDistance || ConstraintType.verticalDistance:
      final (Offset, Offset)? ends = refs.length == 1 ? l(refs[0]) : (p(refs[0]) == null || p(refs[1]) == null ? null : (p(refs[0])!, p(refs[1])!));
      if (ends == null) return null;
      final (a, b) = ends;
      final horizontal = k.type == ConstraintType.horizontalDistance;
      final List<(Offset, Offset)> lines;
      final Offset label;
      if (horizontal) {
        final y = math.min(a.dy, b.dy) - gap;
        lines = [(Offset(a.dx, y), Offset(b.dx, y)), (a, Offset(a.dx, y - over)), (b, Offset(b.dx, y - over))];
        label = Offset((a.dx + b.dx) / 2, y - 9 * px);
      } else {
        final x = math.min(a.dx, b.dx) - gap;
        lines = [(Offset(x, a.dy), Offset(x, b.dy)), (a, Offset(x - over, a.dy)), (b, Offset(x - over, b.dy))];
        label = Offset(x - 9 * px, (a.dy + b.dy) / 2);
      }
      return ConstraintMark(k, label, text(format(k.value)), lines);
    case ConstraintType.distance:
      final kinds = [for (final r in refs) r.kind];
      final Offset a, b;
      var aligned = false;
      if (kinds.length == 1) {
        final line = l(refs[0]);
        if (line == null) return null;
        (a, b) = line;
        aligned = true;
      } else if (!kinds.contains(GeoKind.line)) {
        if (p(refs[0]) == null || p(refs[1]) == null) return null;
        (a, b) = (p(refs[0])!, p(refs[1])!);
        aligned = true;
      } else {
        // From a point (or the second line's middle) square to the line.
        final lineRef = kinds[0] == GeoKind.line ? refs[0] : refs[1];
        final other = identical(lineRef, refs[0]) ? refs[1] : refs[0];
        final line = l(lineRef), q = p(other);
        if (line == null || q == null) return null;
        final d = line.$2 - line.$1;
        final t = d.distanceSquared == 0 ? 0.0 : ((q - line.$1).dx * d.dx + (q - line.$1).dy * d.dy) / d.distanceSquared;
        (a, b) = (q, line.$1 + d * t);
      }
      final lines = <(Offset, Offset)>[];
      Offset label;
      final d = b - a;
      final n = d.distance == 0 ? const Offset(0, -1) : Offset(d.dy, -d.dx) / d.distance;
      if (aligned) {
        // Beside it, away from its shape.
        var out = n;
        final centre = centreOf(refs.first.element);
        final mid = (a + b) / 2;
        if (centre != null && ((mid + out) - centre).distance < ((mid - out) - centre).distance) out = -out;
        lines.addAll([(a + out * gap, b + out * gap), (a, a + out * (gap + over)), (b, b + out * (gap + over))]);
        label = mid + out * (gap + 10 * px);
      } else {
        lines.add((a, b));
        label = (a + b) / 2 + n * (10 * px);
      }
      return ConstraintMark(k, label, text(format(k.value)), lines);
    default:
      return null;
  }
}
