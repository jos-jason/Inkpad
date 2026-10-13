import 'dart:math' as math;
import 'dart:ui';

import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import 'pathfinder.dart';

/// Woodworking helpers for Make mode: corner relief for round bits, and
/// finger-jointed boxes.
class MakeOps {
  MakeOps._();

  /// Corners a round bit can't cut square, as (corner, direction into the
  /// shape along the bisector, the direction along the shorter adjacent
  /// edge, away from the corner). [convex] picks outside corners (for holes) or inside
  /// corners (for parts).
  static List<(Offset, Offset, Offset)> _corners(InkPath p, {required bool convex}) {
    final n = p.nodes;
    if (!p.closed || n.length < 3) return const [];
    // Orientation: positive when clockwise on screen (y down).
    var area = 0.0;
    for (var i = 0; i < n.length; i++) {
      final a = n[i].anchorPoint, b = n[(i + 1) % n.length].anchorPoint;
      area += a.dx * b.dy - b.dx * a.dy;
    }
    final out = <(Offset, Offset, Offset)>[];
    for (var i = 0; i < n.length; i++) {
      final node = n[i], prev = n[(i - 1 + n.length) % n.length], next = n[(i + 1) % n.length];
      // Directions arriving at and leaving the corner (along the curves' ends).
      final inFrom = node.hasInPoint ? node.inPoint : (prev.hasOutPoint ? prev.outPoint : prev.anchorPoint);
      final outTo = node.hasOutPoint ? node.outPoint : (next.hasInPoint ? next.inPoint : next.anchorPoint);
      final din = node.anchorPoint - inFrom, dout = outTo - node.anchorPoint;
      if (din.distance < 1e-9 || dout.distance < 1e-9) continue;
      final u = din / din.distance, v = dout / dout.distance;
      final turn = math.acos((u.dx * v.dx + u.dy * v.dy).clamp(-1.0, 1.0));
      if (turn < 15 * math.pi / 180) continue; // smooth or nearly straight
      final cross = u.dx * v.dy - u.dy * v.dx;
      final isConvex = cross * area > 0;
      if (isConvex != convex) continue;
      // Into the shape at a convex corner; out of it at a concave one.
      var bis = -u + v;
      if (bis.distance < 1e-9) continue;
      bis = bis / bis.distance;
      final lenIn = (node.anchorPoint - prev.anchorPoint).distance, lenOut = (next.anchorPoint - node.anchorPoint).distance;
      final along = lenOut >= lenIn ? -u : v;
      out.add((node.anchorPoint, bis, along));
    }
    return out;
  }

  /// Adds relief at corners so a round bit of [radius] leaves room for a
  /// square-cornered part: a hole ([forHole]) gets "ears" past its corners;
  /// a part gets notches in its inside corners. [tBone] puts the relief
  /// along the shorter side (past a slot's ends) instead of on the
  /// diagonal. Null if there was nothing to relieve.
  static InkStylable? dogbones(InkStylable shape, double radius, {required bool forHole, bool tBone = false}) {
    final paths = switch (shape) {
      InkPath p => [p],
      InkCompoundPath c => c.subpaths,
      _ => const <InkPath>[],
    };
    final circles = <InkStylable>[];
    for (final p in paths) {
      for (final (corner, bis, along) in _corners(p, convex: forHole)) {
        // For a part, the relief goes out of the shape (into the waste).
        final dir = tBone ? (forHole ? along : _awayFromShape(along, bis)) : bis;
        final center = corner + dir * radius;
        circles.add(InkPath.oval(Rect.fromCircle(center: center, radius: radius)));
      }
    }
    if (circles.isEmpty) return null;
    return Pathfinder.combine([shape, ...circles], forHole ? BooleanOp.unite : BooleanOp.subtractFront);
  }

  static Offset _awayFromShape(Offset along, Offset outward) => (along.dx * outward.dx + along.dy * outward.dy) >= 0 ? along : -along;

  /// Copies of [elements] in a grid: [columns] × [rows], each [pitchX] /
  /// [pitchY] apart (center to center). The originals are the first copy.
  static List<InkElement> grid(List<InkElement> elements, {required int columns, required int rows, required double pitchX, required double pitchY}) => [
        for (var r = 0; r < rows; r++)
          for (var c = 0; c < columns; c++)
            if (r != 0 || c != 0)
              for (final e in elements) e.clone()..transform(Affine.translation(c * pitchX, r * pitchY)),
      ];

  /// Copies of [elements] turned around [center], [count] in all (the
  /// originals first), [stepDegrees] apart.
  static List<InkElement> circular(List<InkElement> elements, {required int count, required Offset center, required double stepDegrees}) => [
        for (var i = 1; i < count; i++)
          for (final e in elements) e.clone()..transform(Affine.rotationAbout(center, i * stepDegrees * math.pi / 180)),
      ];
}

/// A finger-jointed box's flat panels (outer dimensions), ready to cut.
class BoxMaker {
  /// Outside width (x), depth (y) and height (z).
  final double width, depth, height;

  /// Material thickness.
  final double thickness;

  /// Aimed-for finger width (the actual one divides each edge evenly).
  final double fingerWidth;

  /// Gap for a good fit: fingers are made this much narrower in total.
  final double clearance;

  /// Whether the box has a lid panel joined like the bottom.
  final bool closedTop;

  const BoxMaker({
    required this.width,
    required this.depth,
    required this.height,
    required this.thickness,
    required this.fingerWidth,
    this.clearance = 0,
    this.closedTop = false,
  });

  /// An odd number of fingers along [length] (so both ends match).
  int _count(double length) {
    var n = (length / fingerWidth).round();
    if (n < 3) n = 3;
    if (n.isEven) n += 1;
    return n;
  }

  /// One edge, from its start corner to its end, as (position, depth)
  /// steps: depth 0 is the outer edge, [thickness] a notch.
  /// [outAtEnds]: whether this panel's fingers are at the ends.
  List<(double, double)> _edge(double length, {required bool fingers, required bool outAtEnds}) {
    if (!fingers) return [(0, 0), (length, 0)];
    final n = _count(length);
    final w = length / n;
    final pts = <(double, double)>[];
    for (var i = 0; i < n; i++) {
      final out = (i.isEven) == outAtEnds;
      // Fingers a little narrower (and notches wider) for the fit.
      final shrink = out ? clearance / 2 : -clearance / 2;
      final a = i == 0 ? 0.0 : i * w + shrink, b = i == n - 1 ? length : (i + 1) * w - shrink;
      final d = out ? 0.0 : thickness;
      pts.add((a, d));
      pts.add((b, d));
    }
    return pts;
  }

  /// A panel w × h with its four edges (top, right, bottom, left, each
  /// going clockwise), as a closed outline with its top-left at [at].
  InkPath _panel(Offset at, double w, double h, List<({bool fingers, bool outAtEnds})> edges) {
    final steps = [
      _edge(w, fingers: edges[0].fingers, outAtEnds: edges[0].outAtEnds),
      _edge(h, fingers: edges[1].fingers, outAtEnds: edges[1].outAtEnds),
      _edge(w, fingers: edges[2].fingers, outAtEnds: edges[2].outAtEnds),
      _edge(h, fingers: edges[3].fingers, outAtEnds: edges[3].outAtEnds),
    ];
    // Each edge's steps in the panel: along the edge, inset by its depth.
    Offset place(int edge, double s, double d) => switch (edge) {
          0 => Offset(s, d),
          1 => Offset(w - d, s),
          2 => Offset(w - s, h - d),
          _ => Offset(d, h - s),
        };
    final pts = <Offset>[];
    for (var e = 0; e < 4; e++) {
      final st = steps[e];
      // Corners: where this edge and its neighbours' insets meet.
      final startInset = steps[(e + 3) % 4].last.$2, endInset = steps[(e + 1) % 4].first.$2;
      for (var i = 0; i < st.length; i++) {
        var (s, d) = st[i];
        if (i == 0) s = startInset;
        if (i == st.length - 1) s = (e.isEven ? w : h) - endInset;
        pts.add(place(e, s, d));
      }
    }
    final clean = <Offset>[];
    for (final p in pts) {
      if (clean.isEmpty || (clean.last - p).distance > 1e-9) clean.add(p);
    }
    if (clean.length > 1 && (clean.first - clean.last).distance < 1e-9) clean.removeLast();
    return InkPath(nodes: [for (final p in clean) BezierNode.anchor(p + at)], closed: true);
  }

  /// The panels laid out flat from [origin], [gap] apart: front, back,
  /// left, right, bottom (and top), with names.
  List<(String, InkPath)> panels({Offset origin = Offset.zero, double gap = 20}) {
    const f = (fingers: true, outAtEnds: true), fIn = (fingers: true, outAtEnds: false), plain = (fingers: false, outAtEnds: true);
    // The front and back own every corner (their fingers are at the ends);
    // the sides and bottom fit around them.
    final top = closedTop ? f : plain;
    final sideTop = closedTop ? fIn : plain;
    final front = [top, f, f, f];
    final side = [sideTop, fIn, fIn, fIn];
    const bottomEdges = [fIn, f, fIn, f];
    var x = origin.dx, y = origin.dy;
    final out = <(String, InkPath)>[];
    void add(String name, double w, double h, List<({bool fingers, bool outAtEnds})> edges) {
      out.add((name, _panel(Offset(x, y), w, h, edges)));
      x += w + gap;
    }

    add('Front', width, height, front);
    add('Back', width, height, front);
    x = origin.dx;
    y += height + gap;
    add('Left', depth, height, side);
    add('Right', depth, height, side);
    x = origin.dx;
    y += height + gap;
    add('Bottom', width, depth, bottomEdges);
    if (closedTop) add('Top', width, depth, bottomEdges);
    return out;
  }
}
