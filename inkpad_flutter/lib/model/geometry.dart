import 'dart:math' as math;
import 'dart:ui';

/// 2D affine transform, equivalent to CGAffineTransform:
///   x' = a*x + c*y + tx
///   y' = b*x + d*y + ty
class Affine {
  final double a, b, c, d, tx, ty;

  const Affine(this.a, this.b, this.c, this.d, this.tx, this.ty);

  static const identity = Affine(1, 0, 0, 1, 0, 0);

  factory Affine.translation(double x, double y) => Affine(1, 0, 0, 1, x, y);

  factory Affine.scale(double sx, double sy) => Affine(sx, 0, 0, sy, 0, 0);

  factory Affine.rotation(double radians) {
    final cs = math.cos(radians), sn = math.sin(radians);
    return Affine(cs, sn, -sn, cs, 0, 0);
  }

  /// Scale about [center].
  factory Affine.scaleAbout(Offset center, double sx, double sy) =>
      Affine.translation(-center.dx, -center.dy)
          .then(Affine.scale(sx, sy))
          .then(Affine.translation(center.dx, center.dy));

  /// Rotate about [center].
  factory Affine.rotationAbout(Offset center, double radians) =>
      Affine.translation(-center.dx, -center.dy)
          .then(Affine.rotation(radians))
          .then(Affine.translation(center.dx, center.dy));

  /// Returns the transform that applies `this` first, then [other].
  Affine then(Affine o) => Affine(
        a * o.a + b * o.c,
        a * o.b + b * o.d,
        c * o.a + d * o.c,
        c * o.b + d * o.d,
        tx * o.a + ty * o.c + o.tx,
        tx * o.b + ty * o.d + o.ty,
      );

  Affine inverted() {
    final det = a * d - b * c;
    if (det == 0) return identity;
    return Affine(
      d / det,
      -b / det,
      -c / det,
      a / det,
      (c * ty - d * tx) / det,
      (b * tx - a * ty) / det,
    );
  }

  Offset apply(Offset p) =>
      Offset(a * p.dx + c * p.dy + tx, b * p.dx + d * p.dy + ty);

  /// Uniform scale factor (average of axis scales).
  double get scaleFactor =>
      (math.sqrt(a * a + b * b) + math.sqrt(c * c + d * d)) / 2;

  bool get isIdentity => this == identity;

  /// Column-major 4x4 matrix for Canvas.transform.
  List<double> toMatrix4() =>
      [a, b, 0, 0, c, d, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1];

  Map<String, dynamic> toJson() => {'m': [a, b, c, d, tx, ty]};

  factory Affine.fromJson(Map<String, dynamic> j) {
    final m = (j['m'] as List).cast<num>().map((n) => n.toDouble()).toList();
    return Affine(m[0], m[1], m[2], m[3], m[4], m[5]);
  }

  @override
  bool operator ==(Object other) =>
      other is Affine &&
      a == other.a &&
      b == other.b &&
      c == other.c &&
      d == other.d &&
      tx == other.tx &&
      ty == other.ty;

  @override
  int get hashCode => Object.hash(a, b, c, d, tx, ty);
}

/// The angle (radians) swept from [from] to [to] around [pivot], in -π..π.
double sweptAngle(Offset pivot, Offset from, Offset to) {
  final a = (to - pivot).direction - (from - pivot).direction;
  return math.atan2(math.sin(a), math.cos(a));
}

/// Rounds [radians] to the nearest multiple of [stepDegrees].
double snapAngle(double radians, double stepDegrees) {
  final step = stepDegrees * math.pi / 180;
  return (radians / step).round() * step;
}

Offset normalize(Offset v) {
  final len = v.distance;
  return len == 0 ? Offset.zero : v / len;
}

bool collinear(Offset a, Offset b, Offset c) {
  final area = (a.dx * (b.dy - c.dy) + b.dx * (c.dy - a.dy) + c.dx * (a.dy - b.dy)).abs();
  return area < 1.0e-3;
}

/// Distance from point [p] to the segment [a]-[b].
double distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lenSq == 0) return (p - a).distance;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq;
  t = t.clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

Rect rectFromPoints(Offset a, Offset b) => Rect.fromLTRB(
      math.min(a.dx, b.dx),
      math.min(a.dy, b.dy),
      math.max(a.dx, b.dx),
      math.max(a.dy, b.dy),
    );

Rect? unionRects(Rect? a, Rect? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.expandToInclude(b);
}

Map<String, double> offsetToJson(Offset o) => {'x': o.dx, 'y': o.dy};

Offset offsetFromJson(Map<String, dynamic> j) =>
    Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble());

/// Formats a number compactly for SVG output (like printf %g).
String fmt(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var s = v.toStringAsFixed(3);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}
