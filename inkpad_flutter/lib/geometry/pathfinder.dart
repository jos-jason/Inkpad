import 'dart:math' as math;
import 'dart:ui';

import 'package:clipper2/clipper2.dart' as cl;

import '../model/element.dart';
import '../model/style.dart';
import 'curve_fit.dart';

enum BooleanOp { unite, intersect, subtractFront, exclude }

/// Boolean path operations and stroke outlining. Plays the role of
/// Inkpad's WDPathfinder, using the same strategy as its livarot engine:
/// flatten curves into fine polygons, combine the polygons (here with
/// Clipper2), then fit bezier curves back — keeping original corners and
/// new intersection points sharp, and straight edges straight.
class Pathfinder {
  /// Maximum distance between a curve and its flattened polygon.
  static const flatness = 0.02;

  /// Maximum distance between the polygon and the refitted curves.
  static const fitTolerance = 0.12;

  static const _precision = 3;

  /// Combines [shapes] (bottom first). Returns null if nothing is left.
  /// Ported from +[WDPathfinder combinePaths:operation:].
  static InkStylable? combine(List<InkStylable> shapes, BooleanOp op) {
    if (shapes.isEmpty) return null;
    final oracle = _CornerOracle();
    final normalized = [for (final s in shapes) _normalize(s, oracle)];

    var result = normalized.first;
    final rest = normalized.skip(1);
    switch (op) {
      case BooleanOp.unite:
        result = _op(cl.ClipType.union, [for (final p in normalized) ...p], null);
      case BooleanOp.intersect:
        for (final p in rest) {
          result = _op(cl.ClipType.intersection, result, p);
        }
      case BooleanOp.subtractFront:
        result = _op(cl.ClipType.difference, result, [for (final p in rest) ...p]);
      case BooleanOp.exclude:
        for (final p in rest) {
          result = _op(cl.ClipType.xor, result, p);
        }
    }
    return _toShape(result, oracle.isCorner);
  }

  /// The stroke of [shape] as a filled outline (dashes, caps and joins
  /// included). Ported in spirit from -[WDAbstractPath outlineStroke].
  static InkStylable? outlineStroke(InkStylable shape) {
    final s = shape.stroke;
    if (s == null || !s.willRender) return null;
    final closedPolys = <List<Offset>>[], openPolys = <List<Offset>>[];
    for (final (pts, closed) in _flattenSubpaths(shape)) {
      if (s.dashPattern.isNotEmpty) {
        openPolys.addAll(_dash(pts, closed, s.dashPattern));
      } else {
        (closed ? closedPolys : openPolys).add(pts);
      }
    }
    final join = switch (s.join) {
      LineJoin.miter => cl.JoinType.miter,
      LineJoin.round => cl.JoinType.round,
      LineJoin.bevel => cl.JoinType.bevel,
    };
    final end = switch (s.cap) {
      LineCap.butt => cl.EndType.butt,
      LineCap.round => cl.EndType.round,
      LineCap.square => cl.EndType.square,
    };
    final co = cl.ClipperOffset(miterLimit: 4, arcTolerance: flatness * 1000);
    final scale = math.pow(10, _precision).toDouble();
    if (closedPolys.isNotEmpty) co.addPaths(_toPaths(closedPolys).scaledPaths64(scale), joinType: join, endType: cl.EndType.joined);
    if (openPolys.isNotEmpty) co.addPaths(_toPaths(openPolys).scaledPaths64(scale), joinType: join, endType: end);
    final out = co.execute(delta: s.width / 2 * scale).scaledPathsD(1 / scale);
    // Offsets of curves are smooth except where the polygon turns sharply.
    return _toShape(_fromPaths(out), (a, b, c) => turnAngle(a, b, c) > 0.6);
  }

  /// Erases [eraser]'s area from an open path, cutting it into the pieces
  /// that remain. Ported from -[WDPath erase:] for open paths.
  static List<InkPath> eraseOpen(InkPath path, InkStylable eraser) {
    final oracle = _CornerOracle();
    final line = _flattenPath(path, oracle);
    final eraserPolys = _normalize(eraser, _CornerOracle());
    final c = cl.ClipperD(roundingDecimalPrecision: _precision);
    c.addOpenSubjects(_toPaths([line]));
    c.addPaths(eraserPolys, cl.PathType.clip);
    final open = c.execute(cl.ClipType.difference, cl.FillRule.nonZero)?.open ?? const [];
    final pieces = <InkPath>[];
    for (final poly in _fromPaths(open)) {
      if (poly.length < 2) continue;
      final n = poly.length;
      // Clipper may return a piece backwards; keep the original direction.
      final nodes = fitNodes(
        poly,
        closed: false,
        isCorner: (i) => i == 0 || i == n - 1 || oracle.isCorner(poly[i - 1], poly[i], poly[i + 1]),
        tolerance: fitTolerance,
      );
      if (nodes.length >= 2) pieces.add(InkPath(nodes: nodes));
    }
    return pieces;
  }

  /// Smooths a hand-drawn polyline into a bezier path, as Inkpad's
  /// WDCurveFit did for its freehand, brush and eraser tools. [tolerance]
  /// is in document units (larger is smoother). With [close], the result
  /// is a closed shape; otherwise it closes only if the ends nearly meet.
  static InkPath? smooth(List<Offset> points, {required double tolerance, bool close = false}) {
    // Drop points closer together than a fraction of the tolerance.
    final pts = <Offset>[];
    for (final p in points) {
      if (pts.isEmpty || (p - pts.last).distance >= tolerance * 0.25) pts.add(p);
    }
    if (pts.length < 2) return null;
    final closed = close || (pts.length > 3 && (pts.first - pts.last).distance < tolerance * 2);
    if (closed && (pts.first - pts.last).distance < tolerance * 2) pts.removeLast();
    final n = pts.length;
    if (n < 2 || (closed && n < 3)) return null;
    // Only very sharp turns (doubling back) stay as corners.
    final nodes = fitNodes(
      pts,
      closed: closed,
      isCorner: (i) => n > 2 && turnAngle(pts[(i - 1 + n) % n], pts[i], pts[(i + 1) % n]) > 2.2 && i > 0 && i < n - 1,
      tolerance: tolerance,
    );
    return nodes.length < 2 ? null : InkPath(nodes: nodes, closed: closed);
  }

  // ---- Flattening ---------------------------------------------------------

  /// Each subpath of [shape] as a polygon, with whether it was closed.
  static List<(List<Offset>, bool)> _flattenSubpaths(InkStylable shape, [_CornerOracle? oracle]) {
    final subpaths = shape is InkCompoundPath ? shape.subpaths : [shape as InkPath];
    return [
      for (final p in subpaths)
        if (p.nodes.length > 1) (_flattenPath(p, oracle), p.closed),
    ];
  }

  static List<Offset> _flattenPath(InkPath p, _CornerOracle? oracle) {
    final pts = <Offset>[p.nodes.first.anchorPoint];
    oracle?.add(p.nodes.first.anchorPoint, corner: p.nodes.first.isCorner || !p.closed);
    final segs = p.segments.toList();
    for (final (i, s) in segs.indexed) {
      final endNode = p.nodes[(i + 1) % p.nodes.length];
      if (s.isStraight) {
        pts.add(s.b);
      } else {
        // Wang's formula: enough steps to stay within [flatness].
        final dd = math.max((s.a - s.outA * 2 + s.inB).distance, (s.outA - s.inB * 2 + s.b).distance);
        final n = math.max(1, math.sqrt(0.75 * dd / flatness).ceil()).clamp(1, 400);
        for (var k = 1; k <= n; k++) {
          final q = s.pointAt(k / n);
          pts.add(q);
          if (k < n) oracle?.add(q, corner: false);
        }
      }
      oracle?.add(s.b, corner: s.isStraight || endNode.isCorner);
    }
    if (p.closed && pts.length > 1 && (pts.first - pts.last).distance < 1e-9) pts.removeLast();
    return pts;
  }

  /// [shape]'s area as clean polygons (its own fill rule applied).
  static cl.PathsD _normalize(InkStylable shape, _CornerOracle oracle) {
    final polys = [for (final (pts, _) in _flattenSubpaths(shape, oracle)) pts];
    return cl.Clipper.booleanOpD(
      clipType: cl.ClipType.union,
      subject: _toPaths(polys),
      fillRule: shape.fillRule == FillRule.evenOdd ? cl.FillRule.evenOdd : cl.FillRule.nonZero,
      precision: _precision,
    );
  }

  static cl.PathsD _op(cl.ClipType type, cl.PathsD subject, cl.PathsD? clip) => cl.Clipper.booleanOpD(
        clipType: type,
        subject: subject,
        clip: clip,
        fillRule: cl.FillRule.nonZero,
        precision: _precision,
      );

  static cl.PathsD _toPaths(List<List<Offset>> polys) => [
        for (final p in polys) [for (final q in p) cl.PointD(q.dx, q.dy)],
      ];

  static List<List<Offset>> _fromPaths(cl.PathsD paths) => [
        for (final p in paths) [for (final q in p) Offset(q.x, q.y)],
      ];

  /// Splits a polyline into dashes.
  static List<List<Offset>> _dash(List<Offset> pts, bool closed, List<double> pattern) {
    final path = closed ? [...pts, pts.first] : pts;
    final total = pattern.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return [path];
    final dashes = <List<Offset>>[];
    var index = 0, remaining = pattern[0];
    var on = true;
    var current = <Offset>[path.first];
    for (var i = 1; i < path.length; i++) {
      var a = path[i - 1];
      final b = path[i];
      var segLeft = (b - a).distance;
      while (segLeft > 0) {
        final step = math.min(segLeft, remaining);
        final dir = (b - a) / (b - a).distance;
        final p = a + dir * step;
        if (on) current.add(p);
        segLeft -= step;
        remaining -= step;
        a = p;
        if (remaining <= 1e-9) {
          if (on && current.length > 1) dashes.add(current);
          on = !on;
          index = (index + 1) % pattern.length;
          remaining = pattern[index];
          current = [p];
        }
      }
    }
    if (on && current.length > 1) dashes.add(current);
    return dashes;
  }

  // ---- Back to curves ---------------------------------------------------------

  static InkStylable? _toShape(Object result, bool Function(Offset prev, Offset p, Offset next) isCorner) {
    final polys = result is cl.PathsD ? _fromPaths(result) : result as List<List<Offset>>;
    final paths = <InkPath>[];
    for (final poly in polys) {
      if (poly.length < 3) continue;
      final n = poly.length;
      final nodes = fitNodes(
        poly,
        closed: true,
        isCorner: (i) => isCorner(poly[(i - 1 + n) % n], poly[i], poly[(i + 1) % n]),
        tolerance: fitTolerance,
      );
      if (nodes.length >= 2) paths.add(InkPath(nodes: nodes, closed: true));
    }
    if (paths.isEmpty) return null;
    return paths.length == 1 ? paths.single : InkCompoundPath(paths);
  }
}

/// Remembers which flattened input points were corners, so the refit can
/// keep them (and new intersection points) sharp. Points are matched on a
/// fine grid, since Clipper rounds coordinates.
class _CornerOracle {
  static const _grid = 100.0; // 0.01 units
  final Set<(int, int)> _corners = {};
  final Set<(int, int)> _smooth = {};

  (int, int) _key(Offset p) => ((p.dx * _grid).round(), (p.dy * _grid).round());

  void add(Offset p, {required bool corner}) => (corner ? _corners : _smooth).add(_key(p));

  bool _near(Set<(int, int)> set, Offset p) {
    final (x, y) = _key(p);
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        if (set.contains((x + dx, y + dy))) return true;
      }
    }
    return false;
  }

  /// Sharp if it was a corner, or a new point (where outlines crossed).
  bool isCorner(Offset prev, Offset p, Offset next) => _near(_corners, p) || !_near(_smooth, p);
}

/// Inkpad's "Add Anchor Points": a new point halfway along every segment,
/// keeping the shape exactly.
void addAnchorsToPath(InkPath p) {
  for (var i = p.segments.length - 1; i >= 0; i--) {
    p.insertAnchor(i, 0.5);
  }
}
