import 'dart:math' as math;
import 'dart:ui';

import '../model/bezier_node.dart';
import '../model/geometry.dart';

/// A cubic bezier piece.
typedef Cubic = (Offset, Offset, Offset, Offset);

/// Fits cubic beziers through [points] within [tolerance], using Philip
/// Schneider's algorithm ("An Algorithm for Automatically Fitting Digitized
/// Curves", Graphics Gems, 1990) — the same approach as Inkpad's CurveFit.
///
/// [startTangent] / [endTangent] fix the curve's direction at each end
/// (unit vectors pointing into the curve); otherwise they come from the
/// neighbouring points.
List<Cubic> fitCubics(List<Offset> points, double tolerance, {Offset? startTangent, Offset? endTangent}) {
  final d = _dedupe(points);
  if (d.length < 2) return [];
  final t1 = startTangent ?? normalize(d[1] - d[0]);
  final t2 = endTangent ?? normalize(d[d.length - 2] - d.last);
  final out = <Cubic>[];
  _fit(d, 0, d.length - 1, t1, t2, tolerance, out, 0);
  return out;
}

List<Offset> _dedupe(List<Offset> pts) {
  final out = <Offset>[];
  for (final p in pts) {
    if (out.isEmpty || (out.last - p).distance > 1e-9) out.add(p);
  }
  return out;
}

void _fit(List<Offset> d, int first, int last, Offset t1, Offset t2, double error, List<Cubic> out, int depth) {
  final count = last - first + 1;
  if (count == 2 || depth > 32) {
    final dist = (d[last] - d[first]).distance / 3;
    out.add((d[first], d[first] + t1 * dist, d[last] + t2 * dist, d[last]));
    return;
  }

  var u = _chordLengths(d, first, last);
  var bez = _generate(d, first, last, u, t1, t2);
  var (maxError, split) = _maxError(d, first, last, bez, u);
  if (maxError < error * error) {
    out.add(bez);
    return;
  }

  // Close: try reparameterizing a few times before splitting.
  if (maxError < error * error * 16) {
    for (var i = 0; i < 4; i++) {
      u = _reparameterize(d, first, last, u, bez);
      bez = _generate(d, first, last, u, t1, t2);
      (maxError, split) = _maxError(d, first, last, bez, u);
      if (maxError < error * error) {
        out.add(bez);
        return;
      }
    }
  }

  // Split at the worst point, with a smooth tangent across the split.
  final center = normalize(d[split - 1] - d[split + 1]);
  _fit(d, first, split, t1, center, error, out, depth + 1);
  _fit(d, split, last, -center, t2, error, out, depth + 1);
}

List<double> _chordLengths(List<Offset> d, int first, int last) {
  final u = <double>[0];
  for (var i = first + 1; i <= last; i++) {
    u.add(u.last + (d[i] - d[i - 1]).distance);
  }
  final total = u.last;
  return total == 0 ? List.filled(u.length, 0) : [for (final v in u) v / total];
}

Offset _bezierAt(Cubic b, double t) {
  final mt = 1 - t;
  return b.$1 * (mt * mt * mt) + b.$2 * (3 * mt * mt * t) + b.$3 * (3 * mt * t * t) + b.$4 * (t * t * t);
}

/// Least-squares control points for fixed end tangents.
Cubic _generate(List<Offset> d, int first, int last, List<double> u, Offset t1, Offset t2) {
  final p0 = d[first], p3 = d[last];
  var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0;
  for (var i = 0; i < u.length; i++) {
    final t = u[i], mt = 1 - t;
    final b0 = mt * mt * mt, b1 = 3 * t * mt * mt, b2 = 3 * t * t * mt, b3 = t * t * t;
    final a0 = t1 * b1, a1 = t2 * b2;
    c00 += _dot(a0, a0);
    c01 += _dot(a0, a1);
    c11 += _dot(a1, a1);
    final tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3));
    x0 += _dot(a0, tmp);
    x1 += _dot(a1, tmp);
  }
  final det = c00 * c11 - c01 * c01;
  var alpha1 = det.abs() < 1e-12 ? 0.0 : (x0 * c11 - x1 * c01) / det;
  var alpha2 = det.abs() < 1e-12 ? 0.0 : (c00 * x1 - c01 * x0) / det;
  final segLength = (p3 - p0).distance;
  final eps = 1e-6 * segLength;
  if (alpha1 < eps || alpha2 < eps) {
    // Fall back to the Wu/Barsky heuristic.
    alpha1 = alpha2 = segLength / 3;
  }
  return (p0, p0 + t1 * alpha1, p3 + t2 * alpha2, p3);
}

(double, int) _maxError(List<Offset> d, int first, int last, Cubic b, List<double> u) {
  var maxDist = 0.0;
  var split = (last - first + 1) ~/ 2 + first;
  for (var i = first + 1; i < last; i++) {
    final diff = _bezierAt(b, u[i - first]) - d[i];
    final dist = _dot(diff, diff);
    if (dist >= maxDist) {
      maxDist = dist;
      split = i;
    }
  }
  return (maxDist, split.clamp(first + 1, last - 1));
}

List<double> _reparameterize(List<Offset> d, int first, int last, List<double> u, Cubic b) => [
      for (var i = first; i <= last; i++) _newton(b, d[i], u[i - first]),
    ];

double _newton(Cubic b, Offset p, double t) {
  final q = _bezierAt(b, t);
  // First and second derivatives.
  final d1 = [(b.$2 - b.$1) * 3, (b.$3 - b.$2) * 3, (b.$4 - b.$3) * 3];
  final d2 = [(d1[1] - d1[0]) * 2, (d1[2] - d1[1]) * 2];
  final mt = 1 - t;
  final q1 = d1[0] * (mt * mt) + d1[1] * (2 * mt * t) + d1[2] * (t * t);
  final q2 = d2[0] * mt + d2[1] * t;
  final num = _dot(q - p, q1);
  final den = _dot(q1, q1) + _dot(q - p, q2);
  if (den == 0) return t;
  return (t - num / den).clamp(0.0, 1.0);
}

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

/// Turns a polyline into bezier nodes: [isCorner] marks the points that
/// must stay sharp; runs between corners are fitted as smooth curves, and
/// runs that are straight stay straight lines with no handles.
List<BezierNode> fitNodes(List<Offset> pts, {required bool closed, required bool Function(int i) isCorner, double tolerance = 0.15}) {
  final p = _dedupe(pts);
  if (closed && p.length > 1 && (p.first - p.last).distance < 1e-9) p.removeLast();
  if (p.length < 2) return [for (final x in p) BezierNode.anchor(x)];

  final n = p.length;
  final corners = [for (var i = 0; i < n; i++) if (isCorner(i) || (!closed && (i == 0 || i == n - 1))) i];

  // Each run is a list of point indices from one corner to the next.
  final runs = <List<int>>[];
  if (closed && corners.isEmpty) {
    // A smooth loop: start anywhere, with matching tangents at the seam.
    runs.add([for (var i = 0; i <= n; i++) i % n]);
  } else if (closed) {
    for (var k = 0; k < corners.length; k++) {
      final a = corners[k], b = corners[(k + 1) % corners.length];
      final run = <int>[a];
      var i = a;
      do {
        i = (i + 1) % n;
        run.add(i);
      } while (i != b);
      runs.add(run);
    }
  } else {
    for (var k = 0; k + 1 < corners.length; k++) {
      runs.add([for (var i = corners[k]; i <= corners[k + 1]; i++) i]);
    }
  }

  // Fit each run, collecting cubic pieces in order.
  final pieces = <(Cubic, bool)>[]; // (cubic, straight)
  for (final run in runs) {
    final rp = [for (final i in run) p[i]];
    if (_isStraight(rp, tolerance)) {
      pieces.add(((rp.first, rp.first, rp.last, rp.last), true));
      continue;
    }
    Offset? t1, t2;
    if (closed && corners.isEmpty) {
      t1 = normalize(p[1] - p[n - 1]);
      t2 = -t1;
    }
    for (final c in fitCubics(rp, tolerance, startTangent: t1, endTangent: t2)) {
      pieces.add((c, false));
    }
  }
  if (pieces.isEmpty) return [for (final x in p) BezierNode.anchor(x)];

  // Join pieces into nodes: node i sits at the start of piece i.
  final nodes = <BezierNode>[];
  for (var i = 0; i < pieces.length; i++) {
    final (c, straight) = pieces[i];
    final prev = i > 0 ? pieces[i - 1] : (closed ? pieces.last : null);
    final inPt = prev == null || prev.$2 ? c.$1 : prev.$1.$3;
    final outPt = straight ? c.$1 : c.$2;
    nodes.add(BezierNode(inPt, c.$1, outPt));
  }
  if (!closed) {
    final (c, straight) = pieces.last;
    nodes.add(BezierNode(straight ? c.$4 : c.$3, c.$4, c.$4));
  }
  return nodes;
}

bool _isStraight(List<Offset> pts, double tolerance) {
  if (pts.length <= 2) return true;
  final a = pts.first, b = pts.last;
  for (final q in pts.skip(1).take(pts.length - 2)) {
    if (distanceToSegment(q, a, b) > tolerance * 0.5) return false;
  }
  return true;
}

/// The turning angle (radians) at [b] between a→b and b→c.
double turnAngle(Offset a, Offset b, Offset c) {
  final v1 = b - a, v2 = c - b;
  if (v1.distance == 0 || v2.distance == 0) return 0;
  final cos = (_dot(v1, v2) / (v1.distance * v2.distance)).clamp(-1.0, 1.0);
  return math.acos(cos);
}
