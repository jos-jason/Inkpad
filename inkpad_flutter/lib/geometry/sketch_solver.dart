import 'dart:math' as math;
import 'dart:ui';

import '../model/bezier_node.dart';
import '../model/constraints.dart';
import '../model/element.dart';
import '../model/geometry.dart';

/// Angles count this many points per radian against lengths, so both
/// weigh about the same in the solver.
const _angleScale = 100.0;

/// The solver's tolerance, in points (about 0.00004 mm).
const solveTolerance = 1e-4;

/// A shape's free values (its parameters) and its points, lines and circles
/// in terms of them. See [GeoRef] for the numbering.
abstract class _Body {
  final InkPath path;

  _Body(this.path);

  /// The parameters as they are now.
  List<double> get initial;

  Offset? point(List<double> x, int o, int i);
  (Offset, Offset)? line(List<double> x, int o, int i);
  (Offset, double)? circle(List<double> x, int o, int i) => null;

  /// Puts parameters [x] (from [o]) back into the shape.
  void write(List<double> x, int o);

  static _Body? of(InkPath p) {
    final live = p.live;
    if (live == null) return p.nodes.isEmpty ? null : _PathBody(p);
    return switch (live.kind) {
      LiveKind.rectangle => _RectBody(p),
      LiveKind.line => _LineBody(p),
      LiveKind.ellipse when (live.width - live.height).abs() < 1e-9 => _CircleBody(p),
      _ => _ShapeBody(p),
    };
  }
}

/// A plain path: every node's position (its handles move with it).
class _PathBody extends _Body {
  late final List<BezierNode> nodes = List.of(path.nodes);
  late final List<bool> straight = [
    for (var i = 0; i < nodes.length; i++)
      i + 1 < nodes.length || path.closed && nodes.length > 1
          ? BezierSegment.between(nodes[i], nodes[(i + 1) % nodes.length]).isStraight
          : false,
  ];

  _PathBody(super.path);

  @override
  List<double> get initial => [for (final n in nodes) ...[n.anchorPoint.dx, n.anchorPoint.dy]];

  @override
  Offset? point(List<double> x, int o, int i) => i >= 0 && i < nodes.length ? Offset(x[o + 2 * i], x[o + 2 * i + 1]) : null;

  @override
  (Offset, Offset)? line(List<double> x, int o, int i) {
    if (i < 0 || i >= nodes.length || !straight[i]) return null;
    return (point(x, o, i)!, point(x, o, (i + 1) % nodes.length)!);
  }

  @override
  void write(List<double> x, int o) {
    path.nodes = [for (final (i, n) in nodes.indexed) n.moveAnchor(Offset(x[o + 2 * i], x[o + 2 * i + 1]) - n.anchorPoint)];
  }
}

/// Shapes placed by a turned frame: x, y (the frame's origin or the
/// centre), angle, width, height. Mirrored frames stay mirrored.
abstract class _FramedBody extends _Body {
  late final LiveShape live = path.live!;
  late final double mirror = live.frame.a * live.frame.d - live.frame.b * live.frame.c < 0 ? -1 : 1;

  _FramedBody(super.path);

  /// The drawing position of [local] (in the shape's own box).
  Offset at(List<double> x, int o, Offset local) {
    final cs = math.cos(x[o + 2]), sn = math.sin(x[o + 2]);
    return Offset(cs * local.dx - mirror * sn * local.dy + x[o], sn * local.dx + mirror * cs * local.dy + x[o + 1]);
  }

  Affine frameFor(List<double> x, int o) {
    final cs = math.cos(x[o + 2]), sn = math.sin(x[o + 2]);
    return Affine(cs, sn, -mirror * sn, mirror * cs, x[o], x[o + 1]);
  }

  double get angle => math.atan2(live.frame.b, live.frame.a);
}

class _RectBody extends _FramedBody {
  _RectBody(super.path);

  @override
  List<double> get initial => [live.frame.tx, live.frame.ty, angle, live.width, live.height];

  Offset? _local(List<double> x, int o, int i) {
    final w = x[o + 3], h = x[o + 4];
    return switch (i) {
      0 => Offset.zero,
      1 => Offset(w, 0),
      2 => Offset(w, h),
      3 => Offset(0, h),
      4 => Offset(w / 2, h / 2),
      _ => null,
    };
  }

  @override
  Offset? point(List<double> x, int o, int i) {
    final l = _local(x, o, i);
    return l == null ? null : at(x, o, l);
  }

  @override
  (Offset, Offset)? line(List<double> x, int o, int i) => i >= 0 && i < 4 ? (point(x, o, i)!, point(x, o, (i + 1) % 4)!) : null;

  @override
  void write(List<double> x, int o) =>
      path.live = live.copyWith(width: math.max(x[o + 3], 1e-6), height: math.max(x[o + 4], 1e-6), frame: frameFor(x, o));
}

/// Live ellipses, polygons and stars: centre, angle, width, height.
class _ShapeBody extends _FramedBody {
  _ShapeBody(super.path);

  @override
  List<double> get initial {
    final c = live.center;
    return [c.dx, c.dy, angle, live.width, live.height];
  }

  int get _corners => switch (live.kind) {
        LiveKind.polygon => live.sides,
        LiveKind.star => live.sides * 2,
        _ => 0,
      };

  @override
  Offset? point(List<double> x, int o, int i) {
    if (i == 0) return Offset(x[o], x[o + 1]);
    final k = i - 1;
    if (k < 0 || k >= _corners) return null;
    final w = x[o + 3] / 2, h = x[o + 4] / 2;
    final star = live.kind == LiveKind.star;
    final a = -math.pi / 2 + k * (star ? math.pi / live.sides : 2 * math.pi / live.sides);
    final r = star && k.isOdd ? live.innerRatio : 1.0;
    return at(x, o, Offset(math.cos(a) * w * r, math.sin(a) * h * r));
  }

  @override
  (Offset, Offset)? line(List<double> x, int o, int i) =>
      i >= 0 && i < _corners ? (point(x, o, i + 1)!, point(x, o, (i + 1) % _corners + 1)!) : null;

  @override
  void write(List<double> x, int o) {
    final w = math.max(x[o + 3], 1e-6), h = math.max(x[o + 4], 1e-6);
    // The frame's origin is the box's corner; x, y is its centre.
    final f = frameFor(x, o);
    final c = f.apply(Offset(w / 2, h / 2)) - Offset(x[o], x[o + 1]);
    path.live = live.copyWith(width: w, height: h, frame: Affine(f.a, f.b, f.c, f.d, f.tx - c.dx, f.ty - c.dy));
  }
}

/// Live circles: centre and radius.
class _CircleBody extends _FramedBody {
  _CircleBody(super.path);

  @override
  List<double> get initial {
    final c = live.center;
    return [c.dx, c.dy, live.width / 2];
  }

  @override
  Offset? point(List<double> x, int o, int i) => i == 0 ? Offset(x[o], x[o + 1]) : null;

  @override
  (Offset, Offset)? line(List<double> x, int o, int i) => null;

  @override
  (Offset, double)? circle(List<double> x, int o, int i) => i == 0 ? (Offset(x[o], x[o + 1]), x[o + 2]) : null;

  @override
  void write(List<double> x, int o) {
    final r = math.max(x[o + 2], 1e-6);
    final f = live.frame;
    final c = Offset(f.a * r + f.c * r, f.b * r + f.d * r);
    path.live = live.copyWith(width: 2 * r, height: 2 * r, frame: Affine(f.a, f.b, f.c, f.d, x[o] - c.dx, x[o + 1] - c.dy));
  }
}

/// Live lines: both ends.
class _LineBody extends _Body {
  _LineBody(super.path);

  @override
  List<double> get initial {
    final n = path.nodes;
    return [n.first.anchorPoint.dx, n.first.anchorPoint.dy, n.last.anchorPoint.dx, n.last.anchorPoint.dy];
  }

  @override
  Offset? point(List<double> x, int o, int i) => switch (i) {
        0 => Offset(x[o], x[o + 1]),
        1 => Offset(x[o + 2], x[o + 3]),
        2 => Offset((x[o] + x[o + 2]) / 2, (x[o + 1] + x[o + 3]) / 2),
        _ => null,
      };

  @override
  (Offset, Offset)? line(List<double> x, int o, int i) => i == 0 ? (point(x, o, 0)!, point(x, o, 1)!) : null;

  @override
  void write(List<double> x, int o) => path.live = LiveShape.line(Offset(x[o], x[o + 1]), Offset(x[o + 2], x[o + 3]));
}

/// The result of solving: whether every constraint is met, and how far off
/// the worst one is (points).
class SolveResult {
  final bool ok;
  final double error;

  const SolveResult(this.ok, this.error);
}

/// Solves sketch constraints (Make mode): finds the smallest change to the
/// shapes' parameters that meets every constraint, by damped least squares
/// (Levenberg–Marquardt), and reports what's still free to move.
class SketchSolver {
  final List<SketchConstraint> constraints;
  final Map<String, _Body> _bodies = {};
  final Map<String, int> _offsets = {};

  /// Constraints whose shapes or parts no longer exist (they're dropped).
  final List<SketchConstraint> invalid = [];

  late List<double> _x;

  /// Builds a solver for [constraints] on the shapes found by id in
  /// [elements].
  SketchSolver(List<SketchConstraint> all, Map<String, InkElement> elements) : constraints = [] {
    var n = 0;
    for (final c in all) {
      var ok = true;
      for (final id in c.elements) {
        if (_bodies.containsKey(id)) continue;
        final e = elements[id];
        final body = e is InkPath ? _Body.of(e) : null;
        if (body == null) {
          ok = false;
          break;
        }
        _bodies[id] = body;
        _offsets[id] = n;
        n += body.initial.length;
      }
      if (ok) {
        constraints.add(c);
      } else {
        invalid.add(c);
      }
    }
    _x = [for (final b in _bodies.values) ...b.initial];
    // Drop constraints whose parts are gone (a point deleted, a side curved).
    constraints.removeWhere((c) {
      final bad = !_valid(c);
      if (bad) invalid.add(c);
      return bad;
    });
  }

  /// Parameters of each shape: where they start, how many.
  Iterable<(String, int, int)> get bodyRanges sync* {
    for (final MapEntry(key: id, value: b) in _bodies.entries) {
      yield (id, _offsets[id]!, b.initial.length);
    }
  }

  int get parameterCount => _x.length;

  bool _valid(SketchConstraint c) {
    for (final r in c.refs) {
      final b = _bodies[r.element];
      if (b == null) return false;
      final o = _offsets[r.element]!;
      final found = switch (r.kind) {
        GeoKind.point => b.point(_x, o, r.index) != null,
        GeoKind.line => b.line(_x, o, r.index) != null,
        GeoKind.circle => b.circle(_x, o, r.index) != null,
      };
      if (!found) return false;
    }
    return _residuals(c, _x, []);
  }

  // ---- Geometry at parameters x ----------------------------------------------

  Offset _p(List<double> x, GeoRef r) {
    final b = _bodies[r.element]!;
    final o = _offsets[r.element]!;
    // A circle's "point" is its centre.
    if (r.kind == GeoKind.circle) return b.circle(x, o, r.index)!.$1;
    if (r.kind == GeoKind.line) {
      final (a, c) = b.line(x, o, r.index)!;
      return (a + c) / 2;
    }
    return b.point(x, o, r.index)!;
  }

  (Offset, Offset) _l(List<double> x, GeoRef r) {
    final b = _bodies[r.element]!;
    return b.line(x, _offsets[r.element]!, r.index)!;
  }

  (Offset, double) _c(List<double> x, GeoRef r) {
    final b = _bodies[r.element]!;
    return b.circle(x, _offsets[r.element]!, r.index)!;
  }

  static double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
  static double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  /// Signed distance of [p] from the line through [a], [b].
  static double _lineDistance(Offset p, Offset a, Offset b) {
    final d = b - a;
    final len = d.distance;
    return len < 1e-12 ? (p - a).distance : _cross(d, p - a) / len;
  }

  /// Adds [c]'s residuals at [x] to [out] (all zero when it's met); false
  /// if its references don't fit its type.
  bool _residuals(SketchConstraint c, List<double> x, List<double> out) {
    final r = c.refs;
    List<GeoKind> kinds = [for (final g in r) g.kind];
    bool are(List<GeoKind> k) => kinds.length == k.length && [for (var i = 0; i < k.length; i++) kinds[i] == k[i]].every((b) => b);
    // Two references in either order: true and [r] swapped to match.
    var refs = r;
    bool either(GeoKind a, GeoKind b) {
      if (are([a, b])) return true;
      if (are([b, a])) {
        refs = [r[1], r[0]];
        kinds = [a, b];
        return true;
      }
      return false;
    }

    switch (c.type) {
      case ConstraintType.coincident:
        if (r.length != 2) return false;
        final d = _p(x, r[0]) - _p(x, r[1]);
        out.addAll([d.dx, d.dy]);
      case ConstraintType.pointOnLine:
        if (!either(GeoKind.point, GeoKind.line)) return false;
        final (a, b) = _l(x, refs[1]);
        out.add(_lineDistance(_p(x, refs[0]), a, b));
      case ConstraintType.pointOnCircle:
        if (!either(GeoKind.point, GeoKind.circle)) return false;
        final (cc, rad) = _c(x, refs[1]);
        out.add((_p(x, refs[0]) - cc).distance - rad);
      case ConstraintType.horizontal || ConstraintType.vertical:
        final (Offset, Offset) ends;
        if (are([GeoKind.line])) {
          ends = _l(x, r[0]);
        } else if (r.length == 2 && kinds.every((k) => k != GeoKind.line)) {
          ends = (_p(x, r[0]), _p(x, r[1]));
        } else {
          return false;
        }
        final (a, b) = ends;
        out.add(c.type == ConstraintType.horizontal ? b.dy - a.dy : b.dx - a.dx);
      case ConstraintType.parallel || ConstraintType.perpendicular:
        if (!are([GeoKind.line, GeoKind.line])) return false;
        final (a1, b1) = _l(x, r[0]);
        final (a2, b2) = _l(x, r[1]);
        final d1 = b1 - a1, d2 = b2 - a2;
        final n = math.max(d1.distance * d2.distance, 1e-12);
        out.add((c.type == ConstraintType.parallel ? _cross(d1, d2) : _dot(d1, d2)) / n * _angleScale);
      case ConstraintType.collinear:
        if (!are([GeoKind.line, GeoKind.line])) return false;
        final (a1, b1) = _l(x, r[0]);
        final (a2, b2) = _l(x, r[1]);
        out.addAll([_lineDistance(a2, a1, b1), _lineDistance(b2, a1, b1)]);
      case ConstraintType.equal:
        if (are([GeoKind.line, GeoKind.line])) {
          final (a1, b1) = _l(x, r[0]);
          final (a2, b2) = _l(x, r[1]);
          out.add((b1 - a1).distance - (b2 - a2).distance);
        } else if (are([GeoKind.circle, GeoKind.circle])) {
          out.add(_c(x, r[0]).$2 - _c(x, r[1]).$2);
        } else {
          return false;
        }
      case ConstraintType.tangent:
        if (either(GeoKind.line, GeoKind.circle)) {
          final (a, b) = _l(x, refs[0]);
          final (cc, rad) = _c(x, refs[1]);
          out.add(_lineDistance(cc, a, b).abs() - rad);
        } else if (are([GeoKind.circle, GeoKind.circle])) {
          final (c1, r1) = _c(x, r[0]);
          final (c2, r2) = _c(x, r[1]);
          out.add((c1 - c2).distance - (c.sign >= 0 ? r1 + r2 : (r1 - r2).abs()));
        } else {
          return false;
        }
      case ConstraintType.concentric:
        if (r.length != 2 || !kinds.contains(GeoKind.circle) || kinds.contains(GeoKind.line)) return false;
        final d = _p(x, r[0]) - _p(x, r[1]);
        out.addAll([d.dx, d.dy]);
      case ConstraintType.midpoint:
        if (!either(GeoKind.point, GeoKind.line)) return false;
        final (a, b) = _l(x, refs[1]);
        final d = _p(x, refs[0]) - (a + b) / 2;
        out.addAll([d.dx, d.dy]);
      case ConstraintType.symmetric:
        if (!are([GeoKind.point, GeoKind.point, GeoKind.line])) return false;
        final p = _p(x, r[0]), q = _p(x, r[1]);
        final (a, b) = _l(x, r[2]);
        final d = b - a;
        final len = math.max(d.distance, 1e-12);
        out.addAll([_lineDistance((p + q) / 2, a, b), _dot(q - p, d) / len]);
      case ConstraintType.fix:
        if (r.length != 1) return false;
        final List<double> now = switch (r[0].kind) {
          GeoKind.point => [_p(x, r[0]).dx, _p(x, r[0]).dy],
          GeoKind.line => [_l(x, r[0]).$1.dx, _l(x, r[0]).$1.dy, _l(x, r[0]).$2.dx, _l(x, r[0]).$2.dy],
          GeoKind.circle => [_c(x, r[0]).$1.dx, _c(x, r[0]).$1.dy, _c(x, r[0]).$2],
        };
        if (c.fixed.length != now.length) return false;
        for (var i = 0; i < now.length; i++) {
          out.add(now[i] - c.fixed[i]);
        }
      case ConstraintType.distance:
        final v = _measure(c, x);
        if (v == null) return false;
        if (!c.reference) out.add(v - c.value);
      case ConstraintType.horizontalDistance || ConstraintType.verticalDistance:
        final v = _measure(c, x);
        if (v == null) return false;
        if (!c.reference) out.add(v - c.value);
      case ConstraintType.angle:
        final v = _measure(c, x);
        if (v == null) return false;
        if (!c.reference) {
          var d = (v - c.value) * math.pi / 180;
          d = math.atan2(math.sin(d), math.cos(d));
          out.add(d * _angleScale);
        }
      case ConstraintType.radius || ConstraintType.diameter:
        final v = _measure(c, x);
        if (v == null) return false;
        if (!c.reference) out.add(v - c.value);
    }
    return true;
  }

  /// A dimension's measurement at [x] (points, or degrees for angles), or
  /// null if its references don't fit.
  double? _measure(SketchConstraint c, List<double> x) {
    final r = c.refs;
    final kinds = [for (final g in r) g.kind];
    switch (c.type) {
      case ConstraintType.distance:
        if (kinds.length == 1 && kinds[0] == GeoKind.line) {
          final (a, b) = _l(x, r[0]);
          return (b - a).distance;
        }
        if (kinds.length != 2) return null;
        if (kinds[0] != GeoKind.line && kinds[1] != GeoKind.line) return (_p(x, r[0]) - _p(x, r[1])).distance;
        if (kinds[0] == GeoKind.line && kinds[1] == GeoKind.line) {
          // Between parallel lines: from the second's middle to the first.
          final (a, b) = _l(x, r[0]);
          return _lineDistance(_p(x, r[1]), a, b).abs();
        }
        final line = kinds[0] == GeoKind.line ? r[0] : r[1], other = kinds[0] == GeoKind.line ? r[1] : r[0];
        final (a, b) = _l(x, line);
        return _lineDistance(_p(x, other), a, b).abs();
      case ConstraintType.horizontalDistance || ConstraintType.verticalDistance:
        final (Offset, Offset) ends;
        if (kinds.length == 1 && kinds[0] == GeoKind.line) {
          ends = _l(x, r[0]);
        } else if (kinds.length == 2 && !kinds.contains(GeoKind.line)) {
          ends = (_p(x, r[0]), _p(x, r[1]));
        } else {
          return null;
        }
        final (a, b) = ends;
        final d = c.type == ConstraintType.horizontalDistance ? b.dx - a.dx : b.dy - a.dy;
        return d * c.sign;
      case ConstraintType.angle:
        if (kinds.length != 2 || kinds.any((k) => k != GeoKind.line)) return null;
        final (a1, b1) = _l(x, r[0]);
        final (a2, b2) = _l(x, r[1]);
        final d1 = b1 - a1, d2 = b2 - a2;
        return math.atan2(_cross(d1, d2), _dot(d1, d2)) * c.sign * 180 / math.pi;
      case ConstraintType.radius || ConstraintType.diameter:
        if (kinds.length != 1 || kinds[0] != GeoKind.circle) return null;
        final rad = _c(x, r[0]).$2;
        return c.type == ConstraintType.radius ? rad : rad * 2;
      default:
        return null;
    }
  }

  /// A dimension's measurement as the shapes are now.
  double? measure(SketchConstraint c) => _measure(c, _x);

  List<double> _all(List<double> x) {
    final out = <double>[];
    for (final c in constraints) {
      _residuals(c, x, out);
    }
    return out;
  }

  /// How far off the worst constraint is now (points).
  double get error => _maxAbs(_all(_x));

  static double _maxAbs(List<double> v) => v.fold(0.0, (m, e) => math.max(m, e.abs()));

  /// The parameter indices of the shapes with ids in [held].
  Set<int> _indices(Set<String> held) => {
        for (final (id, o, n) in bodyRanges)
          if (held.contains(id))
            for (var i = 0; i < n; i++) o + i,
      };

  /// Meets every constraint, changing the shapes as little as it can and
  /// leaving the shapes in [held] alone if possible. The shapes are only
  /// changed when it succeeds.
  SolveResult solve({Set<String> held = const {}}) {
    if (error <= solveTolerance) return SolveResult(true, error);
    if (held.isNotEmpty) {
      final r = _solve(_indices(held));
      if (r.ok) return r;
    }
    return _solve(const {});
  }

  SolveResult _solve(Set<int> fixed) {
    final vars = [for (var i = 0; i < _x.length; i++) if (!fixed.contains(i)) i];
    var x = List.of(_x);
    var r = _all(x);
    var f = _sumSq(r);
    var lambda = 1e-3;
    for (var iter = 0; iter < 200 && _maxAbs(r) > solveTolerance; iter++) {
      final jac = _jacobian(x, r, vars);
      final n = vars.length, m = r.length;
      // Normal equations: (JᵀJ + λI) δ = −Jᵀr.
      final a = List.generate(n, (_) => List<double>.filled(n, 0));
      final g = List<double>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        for (var k = 0; k < m; k++) {
          g[i] += jac[k][i] * r[k];
        }
        for (var j = i; j < n; j++) {
          var s = 0.0;
          for (var k = 0; k < m; k++) {
            s += jac[k][i] * jac[k][j];
          }
          a[i][j] = s;
          a[j][i] = s;
        }
      }
      var improved = false;
      while (lambda < 1e12) {
        final damped = [for (final row in a) List.of(row)];
        for (var i = 0; i < n; i++) {
          damped[i][i] += lambda;
        }
        final step = _solveLinear(damped, [for (final v in g) -v]);
        if (step == null) {
          lambda *= 10;
          continue;
        }
        final trial = List.of(x);
        for (var i = 0; i < n; i++) {
          trial[vars[i]] += step[i];
        }
        final tr = _all(trial);
        final tf = _sumSq(tr);
        if (tf < f) {
          x = trial;
          r = tr;
          f = tf;
          lambda = math.max(lambda / 4, 1e-12);
          improved = true;
          break;
        }
        lambda *= 4;
      }
      if (!improved) break;
    }
    final err = _maxAbs(r);
    final ok = err <= solveTolerance;
    if (ok) {
      _x = x;
      for (final MapEntry(key: id, value: b) in _bodies.entries) {
        b.write(_x, _offsets[id]!);
      }
    }
    return SolveResult(ok, err);
  }

  static double _sumSq(List<double> v) => v.fold(0.0, (s, e) => s + e * e);

  /// ∂residual/∂parameter by central differences, for [vars].
  List<List<double>> _jacobian(List<double> x, List<double> r, List<int> vars) {
    final jac = List.generate(r.length, (_) => List<double>.filled(vars.length, 0));
    final t = List.of(x);
    for (final (j, v) in vars.indexed) {
      final h = 1e-5 * math.max(1, x[v].abs());
      t[v] = x[v] + h;
      final up = _all(t);
      t[v] = x[v] - h;
      final down = _all(t);
      t[v] = x[v];
      for (var k = 0; k < r.length && k < up.length && k < down.length; k++) {
        jac[k][j] = (up[k] - down[k]) / (2 * h);
      }
    }
    return jac;
  }

  /// Solves [a] y = [b] by Gaussian elimination with partial pivoting.
  static List<double>? _solveLinear(List<List<double>> a, List<double> b) {
    final n = b.length;
    for (var col = 0; col < n; col++) {
      var piv = col;
      for (var i = col + 1; i < n; i++) {
        if (a[i][col].abs() > a[piv][col].abs()) piv = i;
      }
      if (a[piv][col].abs() < 1e-300) return null;
      if (piv != col) {
        final t = a[piv];
        a[piv] = a[col];
        a[col] = t;
        final tb = b[piv];
        b[piv] = b[col];
        b[col] = tb;
      }
      for (var i = col + 1; i < n; i++) {
        final f = a[i][col] / a[col][col];
        if (f == 0) continue;
        for (var j = col; j < n; j++) {
          a[i][j] -= f * a[col][j];
        }
        b[i] -= f * b[col];
      }
    }
    final y = List<double>.filled(n, 0);
    for (var i = n - 1; i >= 0; i--) {
      var s = b[i];
      for (var j = i + 1; j < n; j++) {
        s -= a[i][j] * y[j];
      }
      y[i] = s / a[i][i];
    }
    return y;
  }

  // ---- Degrees of freedom -----------------------------------------------------

  /// The constraints' Jacobian rows at the current shapes.
  List<List<double>> _jacobianNow([List<SketchConstraint>? only]) {
    final saved = List.of(constraints);
    if (only != null) {
      constraints
        ..clear()
        ..addAll(only);
    }
    try {
      final r = _all(_x);
      return _jacobian(_x, r, [for (var i = 0; i < _x.length; i++) i]);
    } finally {
      constraints
        ..clear()
        ..addAll(saved);
    }
  }

  /// The rank of [rows] (row echelon form), and the pivot columns.
  static (int, List<int>, List<List<double>>) _echelon(List<List<double>> rows, int n) {
    final m = [for (final r in rows) List.of(r)];
    // Rounding noise from the numeric derivatives isn't a constraint.
    var biggest = 0.0;
    for (final r in m) {
      for (final v in r) {
        biggest = math.max(biggest, v.abs());
      }
    }
    for (final r in m) {
      for (var j = 0; j < n; j++) {
        if (r[j].abs() < 1e-4 * biggest) r[j] = 0;
      }
    }
    // Columns are scaled to unit size, so angles and lengths compare.
    final scale = List<double>.filled(n, 0);
    for (final r in m) {
      for (var j = 0; j < n; j++) {
        scale[j] = math.max(scale[j], r[j].abs());
      }
    }
    for (final r in m) {
      for (var j = 0; j < n; j++) {
        if (scale[j] > 0) r[j] /= scale[j];
      }
    }
    final pivots = <int>[];
    var row = 0;
    for (var col = 0; col < n && row < m.length; col++) {
      var piv = row;
      for (var i = row + 1; i < m.length; i++) {
        if (m[i][col].abs() > m[piv][col].abs()) piv = i;
      }
      if (m[piv][col].abs() < 1e-7) continue;
      final t = m[piv];
      m[piv] = m[row];
      m[row] = t;
      final p = m[row][col];
      for (var j = 0; j < n; j++) {
        m[row][j] /= p;
      }
      for (var i = 0; i < m.length; i++) {
        if (i == row) continue;
        final f = m[i][col];
        if (f == 0) continue;
        for (var j = 0; j < n; j++) {
          m[i][j] -= f * m[row][j];
        }
      }
      pivots.add(col);
      row++;
    }
    return (pivots.length, pivots, m);
  }

  /// How many independent ways the shapes can still move (degrees of
  /// freedom), and the ids of shapes that can't move at all.
  ({int free, Set<String> fixed}) analyse() {
    final n = _x.length;
    final rows = _jacobianNow();
    final (rank, pivots, m) = _echelon(rows, n);
    // Each free column gives a way to move; a parameter is held when no
    // way to move changes it.
    final free = [for (var j = 0; j < n; j++) if (!pivots.contains(j)) j];
    final moves = List<bool>.filled(n, false);
    for (final f in free) {
      moves[f] = true;
      for (final (i, p) in pivots.indexed) {
        if (m[i][f].abs() > 1e-7) moves[p] = true;
      }
    }
    final fixed = <String>{};
    for (final (id, o, count) in bodyRanges) {
      if (![for (var i = 0; i < count; i++) moves[o + i]].contains(true)) fixed.add(id);
    }
    return (free: n - rank, fixed: fixed);
  }

  /// Whether [c] (one of [constraints]) adds nothing the others don't
  /// already settle, so it would over-constrain the sketch.
  bool isRedundant(SketchConstraint c) {
    final n = _x.length;
    final withIt = _echelon(_jacobianNow(), n).$1;
    final without = _echelon(_jacobianNow([for (final o in constraints) if (!identical(o, c)) o]), n).$1;
    return withIt <= without;
  }

  /// Every constraint met now?
  bool get satisfied => error <= solveTolerance;
}

/// The points, straight edges and circles of a shape that constraints can
/// use, with their indices (see [GeoRef]), as the shape is now.
class SketchGeometry {
  final List<(int, Offset)> points;
  final List<(int, Offset, Offset)> lines;
  final List<(int, Offset, double)> circles;

  const SketchGeometry(this.points, this.lines, this.circles);

  static const empty = SketchGeometry([], [], []);

  static SketchGeometry of(InkElement e) {
    final body = e is InkPath ? _Body.of(e) : null;
    if (body == null) return empty;
    final x = body.initial;
    final points = <(int, Offset)>[], lines = <(int, Offset, Offset)>[], circles = <(int, Offset, double)>[];
    // Indices run on until there are no more (with a guard for paths with
    // curved segments in between).
    final limit = e is InkPath && e.live == null ? e.nodes.length : 1000;
    for (var i = 0; i < limit; i++) {
      final p = body.point(x, 0, i);
      if (p == null) break;
      points.add((i, p));
    }
    for (var i = 0; i < limit; i++) {
      final l = body.line(x, 0, i);
      if (l == null) {
        if (e is InkPath && e.live == null) continue; // a curve: skip it
        break;
      }
      lines.add((i, l.$1, l.$2));
    }
    final c = body.circle(x, 0, 0);
    if (c != null) circles.add((0, c.$1, c.$2));
    return SketchGeometry(points, lines, circles);
  }

  Offset? point(int i) => points.where((p) => p.$1 == i).map((p) => p.$2).firstOrNull;
  (Offset, Offset)? line(int i) => lines.where((l) => l.$1 == i).map((l) => (l.$2, l.$3)).firstOrNull;
  (Offset, double)? circle(int i) => circles.where((c) => c.$1 == i).map((c) => (c.$2, c.$3)).firstOrNull;

  /// [r]'s position as a point (a line's middle, a circle's centre).
  Offset? anchor(GeoRef r) => switch (r.kind) {
        GeoKind.point => point(r.index),
        GeoKind.line => line(r.index) == null ? null : (line(r.index)!.$1 + line(r.index)!.$2) / 2,
        GeoKind.circle => circle(r.index)?.$1,
      };
}
