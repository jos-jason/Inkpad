import 'dart:math' as math;
import 'dart:ui';

import 'bezier_node.dart';
import 'geometry.dart';

enum LiveKind { rectangle, ellipse, polygon, star, line }

/// A shape that remembers its dimensions (Make mode), so it can be edited
/// by number — width, height, corner radius, sides — until it's
/// deliberately converted to a plain path. Like Shaper Studio's shapes.
///
/// The shape is laid out in its own box (0, 0, [width], [height]); a line
/// runs from (0, 0) to ([width], 0). [frame] places that box in the
/// drawing: a rotation (or mirror) and a move, with no stretching, so the
/// dimensions stay true.
class LiveShape {
  final LiveKind kind;
  final double width, height;

  /// Rectangle: rounded corners.
  final double cornerRadius;

  /// Polygon sides, or star points.
  final int sides;

  /// Star: inner radius as a fraction of the outer.
  final double innerRatio;

  final Affine frame;

  const LiveShape({
    required this.kind,
    required this.width,
    required this.height,
    this.cornerRadius = 0,
    this.sides = 6,
    this.innerRatio = 0.5,
    this.frame = Affine.identity,
  });

  /// A shape filling [r] (unrotated).
  factory LiveShape.inRect(LiveKind kind, Rect r, {double cornerRadius = 0, int sides = 6, double innerRatio = 0.5}) => LiveShape(
        kind: kind,
        width: r.width,
        height: r.height,
        cornerRadius: cornerRadius,
        sides: sides,
        innerRatio: innerRatio,
        frame: Affine.translation(r.left, r.top),
      );

  /// A line from [a] to [b].
  factory LiveShape.line(Offset a, Offset b) {
    final d = b - a;
    final angle = math.atan2(d.dy, d.dx);
    return LiveShape(kind: LiveKind.line, width: d.distance, height: 0, frame: Affine.rotation(angle).then(Affine.translation(a.dx, a.dy)));
  }

  bool get closed => kind != LiveKind.line;

  /// The rotation of the shape's box, in degrees (clockwise on screen).
  double get angle => math.atan2(frame.b, frame.a) * 180 / math.pi;

  /// The box's corners in the drawing (top-left, top-right, bottom-right,
  /// bottom-left of the shape's own box).
  List<Offset> get corners => [Offset.zero, Offset(width, 0), Offset(width, height), Offset(0, height)].map(frame.apply).toList();

  Offset get center => frame.apply(Offset(width / 2, height / 2));

  /// The outline, in the drawing.
  List<BezierNode> buildNodes() {
    final r = Rect.fromLTWH(0, 0, width, height);
    final local = switch (kind) {
      LiveKind.rectangle => _roundedRect(r, cornerRadius),
      LiveKind.ellipse => _oval(r),
      LiveKind.polygon => [
          for (var i = 0; i < sides; i++)
            BezierNode.anchor(Offset(
              r.center.dx + math.cos(-math.pi / 2 + i * 2 * math.pi / sides) * r.width / 2,
              r.center.dy + math.sin(-math.pi / 2 + i * 2 * math.pi / sides) * r.height / 2,
            )),
        ],
      LiveKind.star => [
          for (var i = 0; i < sides * 2; i++)
            BezierNode.anchor(Offset(
              r.center.dx + math.cos(-math.pi / 2 + i * math.pi / sides) * r.width / 2 * (i.isEven ? 1 : innerRatio),
              r.center.dy + math.sin(-math.pi / 2 + i * math.pi / sides) * r.height / 2 * (i.isEven ? 1 : innerRatio),
            )),
        ],
      LiveKind.line => [const BezierNode.anchor(Offset.zero), BezierNode.anchor(Offset(width, 0))],
    };
    return [for (final n in local) n.transform(frame)];
  }

  static List<BezierNode> _oval(Rect r) {
    const kappa = 0.5522847498;
    final c = r.center;
    final hx = r.width / 2 * kappa, hy = r.height / 2 * kappa;
    return [
      BezierNode(Offset(r.left, c.dy + hy), Offset(r.left, c.dy), Offset(r.left, c.dy - hy)),
      BezierNode(Offset(c.dx - hx, r.top), Offset(c.dx, r.top), Offset(c.dx + hx, r.top)),
      BezierNode(Offset(r.right, c.dy - hy), Offset(r.right, c.dy), Offset(r.right, c.dy + hy)),
      BezierNode(Offset(c.dx + hx, r.bottom), Offset(c.dx, r.bottom), Offset(c.dx - hx, r.bottom)),
    ];
  }

  static List<BezierNode> _roundedRect(Rect r, double radius) {
    final rad = radius.clamp(0.0, math.min(r.width, r.height) / 2);
    if (rad <= 0) {
      return [BezierNode.anchor(r.topLeft), BezierNode.anchor(r.topRight), BezierNode.anchor(r.bottomRight), BezierNode.anchor(r.bottomLeft)];
    }
    const k = 0.5522847498;
    final kr = rad * k;
    BezierNode node(double ix, double iy, double ax, double ay, double ox, double oy) =>
        BezierNode(Offset(ix, iy), Offset(ax, ay), Offset(ox, oy));
    final l = r.left, t = r.top, rt = r.right, b = r.bottom;
    return [
      node(l + rad - kr, t, l + rad, t, l + rad, t),
      node(rt - rad, t, rt - rad, t, rt - rad + kr, t),
      node(rt, t + rad - kr, rt, t + rad, rt, t + rad),
      node(rt, b - rad, rt, b - rad, rt, b - rad + kr),
      node(rt - rad + kr, b, rt - rad, b, rt - rad, b),
      node(l + rad, b, l + rad, b, l + rad - kr, b),
      node(l, b - rad + kr, l, b - rad, l, b - rad),
      node(l, t + rad, l, t + rad, l, t + rad - kr),
    ];
  }

  LiveShape copyWith({double? width, double? height, double? cornerRadius, int? sides, double? innerRatio, Affine? frame}) => LiveShape(
        kind: kind,
        width: width ?? this.width,
        height: height ?? this.height,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        sides: sides ?? this.sides,
        innerRatio: innerRatio ?? this.innerRatio,
        frame: frame ?? this.frame,
      );

  /// Resized to [w] × [h], keeping the box's [anchor] corner in place
  /// (0: top-left … as in [corners]) or its center when null.
  LiveShape resized({double? w, double? h, int? anchor = 0}) {
    final nw = math.max(w ?? width, 0.0), nh = kind == LiveKind.line ? 0.0 : math.max(h ?? height, 0.0);
    final oldLocal = anchor == null ? Offset(width / 2, height / 2) : [Offset.zero, Offset(width, 0), Offset(width, height), Offset(0, height)][anchor];
    final newLocal = anchor == null ? Offset(nw / 2, nh / 2) : [Offset.zero, Offset(nw, 0), Offset(nw, nh), Offset(0, nh)][anchor];
    final pinned = frame.apply(oldLocal);
    final moved = frame.apply(newLocal);
    final shift = pinned - moved;
    return copyWith(width: nw, height: nh, frame: frame.then(Affine.translation(shift.dx, shift.dy)));
  }

  /// Turned to [degrees] about its center.
  LiveShape rotatedTo(double degrees) {
    final c = center;
    final t = Affine.rotationAbout(c, (degrees - angle) * math.pi / 180);
    return copyWith(frame: frame.then(t));
  }

  /// This shape after the drawing transform [t]: moves, rotations, mirrors
  /// and scaling along its own sides keep it live; anything that would
  /// skew it returns null (it then becomes a plain path).
  LiveShape? transformed(Affine t) {
    final m = frame.then(t);
    final u = Offset(m.a, m.b), v = Offset(m.c, m.d);
    final su = u.distance, sv = v.distance;
    if (su < 1e-9) return null;
    final origin = Offset(m.tx, m.ty);
    if (kind == LiveKind.line) {
      final dir = u / su;
      return copyWith(width: width * su, frame: Affine(dir.dx, dir.dy, -dir.dy, dir.dx, origin.dx, origin.dy));
    }
    if (sv < 1e-9) return null;
    final cosine = (u.dx * v.dx + u.dy * v.dy) / (su * sv);
    if (cosine.abs() > 1e-6) return null; // skewed
    final du = u / su, dv = v / sv;
    return copyWith(width: width * su, height: height * sv, frame: Affine(du.dx, du.dy, dv.dx, dv.dy, origin.dx, origin.dy));
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'w': width,
        'h': height,
        if (cornerRadius != 0) 'r': cornerRadius,
        if (kind == LiveKind.polygon || kind == LiveKind.star) 'sides': sides,
        if (kind == LiveKind.star) 'inner': innerRatio,
        'frame': frame.toJson(),
      };

  factory LiveShape.fromJson(Map<String, dynamic> j) => LiveShape(
        kind: LiveKind.values.byName(j['kind'] as String),
        width: (j['w'] as num).toDouble(),
        height: (j['h'] as num).toDouble(),
        cornerRadius: (j['r'] as num?)?.toDouble() ?? 0,
        sides: j['sides'] as int? ?? 6,
        innerRatio: (j['inner'] as num?)?.toDouble() ?? 0.5,
        frame: Affine.fromJson(j['frame']),
      );

  @override
  bool operator ==(Object other) =>
      other is LiveShape &&
      other.kind == kind &&
      other.width == width &&
      other.height == height &&
      other.cornerRadius == cornerRadius &&
      other.sides == sides &&
      other.innerRatio == innerRatio &&
      other.frame == frame;

  @override
  int get hashCode => Object.hash(kind, width, height, cornerRadius, sides, innerRatio, frame);
}
