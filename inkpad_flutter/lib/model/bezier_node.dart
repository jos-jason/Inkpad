import 'dart:math' as math;
import 'dart:ui';

import 'geometry.dart';

/// How moving one control handle affects the opposite handle.
/// Ported from WDBezierNodeReflectionMode.
enum ReflectionMode {
  /// Opposite handle mirrors both angle and length.
  reflect,

  /// Handles move independently (corner).
  independent,

  /// Opposite handle mirrors angle but keeps its own length (smooth).
  reflectIndependent,
}

enum HandleKind { inPoint, anchor, outPoint }

/// An anchor point with in/out control handles. Immutable, like WDBezierNode.
class BezierNode {
  final Offset inPoint;
  final Offset anchorPoint;
  final Offset outPoint;

  const BezierNode(this.inPoint, this.anchorPoint, this.outPoint);

  const BezierNode.anchor(Offset pt)
      : inPoint = pt,
        anchorPoint = pt,
        outPoint = pt;

  bool get hasInPoint => inPoint != anchorPoint;
  bool get hasOutPoint => outPoint != anchorPoint;

  bool get isCorner =>
      !hasInPoint || !hasOutPoint || !collinear(inPoint, anchorPoint, outPoint);

  ReflectionMode get reflectionMode {
    // Normalize the handle points, then test whether they are collinear.
    final a = anchorPoint + normalize(inPoint - anchorPoint);
    final b = anchorPoint + normalize(outPoint - anchorPoint);
    if (collinear(anchorPoint, a, b) && inPoint != outPoint) {
      return ReflectionMode.reflectIndependent;
    }
    return ReflectionMode.independent;
  }

  BezierNode transform(Affine t) =>
      BezierNode(t.apply(inPoint), t.apply(anchorPoint), t.apply(outPoint));

  BezierNode chopHandles() => BezierNode.anchor(anchorPoint);
  BezierNode chopOutHandle() => BezierNode(inPoint, anchorPoint, anchorPoint);
  BezierNode chopInHandle() => BezierNode(anchorPoint, anchorPoint, outPoint);

  /// Swaps in/out handles (used when reversing a path).
  BezierNode flipped() => BezierNode(outPoint, anchorPoint, inPoint);

  BezierNode moveAnchor(Offset delta) =>
      BezierNode(inPoint + delta, anchorPoint + delta, outPoint + delta);

  /// Sets the in handle by reflecting [pt] through the anchor
  /// (used when closing a path with the pen tool).
  BezierNode setInPoint(Offset pt, ReflectionMode mode) {
    final flipped = anchorPoint + (anchorPoint - pt);
    return moveControlHandle(HandleKind.inPoint, flipped, mode);
  }

  BezierNode moveControlHandle(HandleKind which, Offset pt, ReflectionMode mode) {
    var inPt = inPoint, outPt = outPoint;

    if (which == HandleKind.inPoint) {
      inPt = pt;
      if (mode == ReflectionMode.reflect) {
        outPt = anchorPoint + (anchorPoint - inPt);
      } else if (mode == ReflectionMode.reflectIndependent) {
        final magnitude = (outPoint - anchorPoint).distance;
        final dir = normalize(anchorPoint - inPt);
        // If the direction is zero we'd chop the other handle; don't.
        if (dir != Offset.zero) outPt = anchorPoint + dir * magnitude;
      }
    } else if (which == HandleKind.outPoint) {
      outPt = pt;
      if (mode == ReflectionMode.reflect) {
        inPt = anchorPoint + (anchorPoint - outPt);
      } else if (mode == ReflectionMode.reflectIndependent) {
        final magnitude = (inPoint - anchorPoint).distance;
        final dir = normalize(anchorPoint - outPt);
        if (dir != Offset.zero) inPt = anchorPoint + dir * magnitude;
      }
    }
    return BezierNode(inPt, anchorPoint, outPt);
  }

  Map<String, dynamic> toJson() => {
        'in': offsetToJson(inPoint),
        'a': offsetToJson(anchorPoint),
        'out': offsetToJson(outPoint),
      };

  factory BezierNode.fromJson(Map<String, dynamic> j) => BezierNode(
        offsetFromJson(j['in']),
        offsetFromJson(j['a']),
        offsetFromJson(j['out']),
      );

  @override
  bool operator ==(Object other) =>
      other is BezierNode &&
      inPoint == other.inPoint &&
      anchorPoint == other.anchorPoint &&
      outPoint == other.outPoint;

  @override
  int get hashCode => Object.hash(inPoint, anchorPoint, outPoint);
}

/// A cubic segment between two nodes. Ported from WDBezierSegment.
class BezierSegment {
  final Offset a, outA, inB, b;

  const BezierSegment(this.a, this.outA, this.inB, this.b);

  factory BezierSegment.between(BezierNode n1, BezierNode n2) =>
      BezierSegment(n1.anchorPoint, n1.outPoint, n2.inPoint, n2.anchorPoint);

  bool get isStraight => a == outA && inB == b;

  /// The exact bounds of the curve (not just its control points), in full
  /// precision.
  Rect get bounds {
    var minX = math.min(a.dx, b.dx), maxX = math.max(a.dx, b.dx);
    var minY = math.min(a.dy, b.dy), maxY = math.max(a.dy, b.dy);
    if (!isStraight) {
      // Where the curve turns: roots of its derivative, per axis.
      for (final t in [..._extrema(a.dx, outA.dx, inB.dx, b.dx), ..._extrema(a.dy, outA.dy, inB.dy, b.dy)]) {
        final p = pointAt(t);
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static List<double> _extrema(double p0, double p1, double p2, double p3) {
    final a = -p0 + 3 * p1 - 3 * p2 + p3, b = 2 * (p0 - 2 * p1 + p2), c = p1 - p0;
    final out = <double>[];
    void add(double t) {
      if (t > 0 && t < 1) out.add(t);
    }

    if (a.abs() < 1e-12) {
      if (b.abs() > 1e-12) add(-c / b);
      return out;
    }
    final disc = b * b - 4 * a * c;
    if (disc < 0) return out;
    final s = math.sqrt(disc);
    add((-b + s) / (2 * a));
    add((-b - s) / (2 * a));
    return out;
  }

  Offset pointAt(double t) {
    final mt = 1 - t;
    return a * (mt * mt * mt) +
        outA * (3 * mt * mt * t) +
        inB * (3 * mt * t * t) +
        b * (t * t * t);
  }

  /// Splits at [t] using de Casteljau; returns the two halves.
  (BezierSegment, BezierSegment) splitAt(double t) {
    Offset lerp(Offset p, Offset q) => p + (q - p) * t;
    final ab = lerp(a, outA), bc = lerp(outA, inB), cd = lerp(inB, b);
    final abc = lerp(ab, bc), bcd = lerp(bc, cd);
    final mid = lerp(abc, bcd);
    return (BezierSegment(a, ab, abc, mid), BezierSegment(mid, bcd, cd, b));
  }

  /// Returns (distance, t) of the closest point on the curve to [p],
  /// found by sampling and then refining.
  (double, double) closestPoint(Offset p, {int samples = 32}) {
    var bestT = 0.0, bestD = double.infinity;
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      final d = (pointAt(t) - p).distance;
      if (d < bestD) {
        bestD = d;
        bestT = t;
      }
    }
    // Refine by bisection-style local search.
    var step = 1.0 / samples;
    for (var iter = 0; iter < 12; iter++) {
      step /= 2;
      for (final t in [bestT - step, bestT + step]) {
        if (t < 0 || t > 1) continue;
        final d = (pointAt(t) - p).distance;
        if (d < bestD) {
          bestD = d;
          bestT = t;
        }
      }
    }
    return (bestD, bestT);
  }
}
