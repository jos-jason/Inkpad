import 'dart:math' as math;
import 'dart:ui';

import '../model/bezier_node.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import 'pathfinder.dart';

/// An arrowhead shape, drawn at the ends of open paths in the stroke color
/// and scaled by the stroke width. Ported from WDArrowhead.
///
/// Arrows are defined in a 7×7 box pointing right (+x). The [attachment] is
/// where the trimmed line meets the arrow; [capAdjustment] moves it for butt
/// caps so the line doesn't show a gap.
class Arrowhead {
  final String id;
  final String label;
  final List<InkPath> contours;
  final Offset attachment;
  final Offset capAdjustment;
  final Rect bounds;

  Arrowhead._(this.id, this.label, List<InkPath> contours, Offset attachment, [this.capAdjustment = Offset.zero])
      : contours = _normalized(contours),
        attachment = attachment - _origin(contours),
        bounds = _bounds(contours).shift(-_origin(contours));

  static const _size = 7.0, _half = _size / 2;

  /// Inkpad's arrowheads, in the order its picker lists them.
  static const ids = [
    'arrow1', 'arrow2', 'arrow3', 'T shape', 'closed circle', 'closed square',
    'closed diamond', 'open circle', 'open square', 'open diamond',
  ];

  static Arrowhead? named(String id) => id.isEmpty ? null : _all[id];

  static final Map<String, Arrowhead> _all = {for (final a in _build()) a.id: a};

  Offset attachmentAdjusted(bool butt) => butt ? attachment + capAdjustment : attachment;

  /// How far back from the path's end the line is trimmed (in stroke widths).
  double insetLength(bool butt) => bounds.width - attachmentAdjusted(butt).dx;

  /// Arrow space to document space: the attachment at [point], pointing
  /// along [angle], scaled by the stroke width.
  Affine transformAt(Offset point, double scale, double angle, bool butt) {
    final a = attachmentAdjusted(butt);
    return Affine.translation(-a.dx, -a.dy)
        .then(Affine.rotation(angle))
        .then(Affine.scale(scale, scale))
        .then(Affine.translation(point.dx, point.dy));
  }

  /// The arrow's outline placed in the document.
  List<InkPath> placed(Offset point, double scale, double angle, bool butt) {
    final t = transformAt(point, scale, angle, butt);
    return [for (final c in contours) InkPath(nodes: [for (final n in c.nodes) n.transform(t)], closed: true)];
  }

  /// A flutter path of [contours] at the given place (even-odd: open
  /// shapes have holes).
  Path path(Offset point, double scale, double angle, bool butt) {
    final p = Path()..fillType = PathFillType.evenOdd;
    for (final c in placed(point, scale, angle, butt)) {
      p.addPath(c.toFlutterPath(), Offset.zero);
    }
    return p;
  }

  static Offset _origin(List<InkPath> contours) => _bounds(contours).topLeft;

  static Rect _bounds(List<InkPath> contours) => contours.map((c) => c.bounds).reduce((a, b) => a.expandToInclude(b));

  static List<InkPath> _normalized(List<InkPath> contours) {
    final o = _origin(contours);
    final t = Affine.translation(-o.dx, -o.dy);
    return [for (final c in contours) InkPath(nodes: [for (final n in c.nodes) n.transform(t)], closed: true)];
  }

  static InkPath _poly(List<Offset> pts) => InkPath(nodes: [for (final p in pts) BezierNode.anchor(p)], closed: true);

  static List<InkPath> _outline(InkPath line, LineCap cap) {
    line.stroke = StrokeStyle(width: 1, cap: cap, join: LineJoin.miter);
    final o = Pathfinder.outlineStroke(line);
    return switch (o) {
      InkPath p => [p],
      InkCompoundPath c => c.subpaths,
      _ => const [],
    };
  }

  /// Ported from +[WDArrowhead buildArrows].
  static List<Arrowhead> _build() {
    const box = Rect.fromLTWH(0, 0, _size, _size);
    // A diamond: the square [inset] in from the box, turned 45° about its center.
    List<Offset> diamond(double inset) {
      final r = (_half - inset) * math.sqrt2;
      return [Offset(_half - r, _half), Offset(_half, _half - r), Offset(_half + r, _half), Offset(_half, _half + r)];
    }

    final chevron = InkPath(nodes: [
      const BezierNode.anchor(Offset(_size / 3 + 0.5, _size - 0.5)),
      const BezierNode.anchor(Offset(_size - 0.5, _half)),
      const BezierNode.anchor(Offset(_size / 3 + 0.5, 0.5)),
    ]);
    // The open diamond is the closed one's outline, 1 wide (miter joins).
    final openDiamond = [_poly(diamond(1.5 - 0.5)), _poly(diamond(1.5 + 0.5))];
    final diamondTip = diamond(1.5).first;

    return [
      Arrowhead._('arrow1', 'Arrow', [
        _poly([const Offset(3 / 8 * _size, _half), const Offset(0, _size), const Offset(_size, _half), Offset.zero]),
      ], const Offset(_half, _half)),
      Arrowhead._('arrow2', 'Triangle', [
        _poly([const Offset(0, _size), const Offset(_size - 1, _half), Offset.zero]),
      ], const Offset(1.5, _half)),
      Arrowhead._('arrow3', 'Open arrow', _outline(chevron, LineCap.round), const Offset(_size - 1, _half)),
      Arrowhead._('T shape', 'Bar', [_poly(const [Offset(0, 0.5), Offset(1, 0.5), Offset(1, _size - 0.5), Offset(0, _size - 0.5)])],
          const Offset(0.25, _half), const Offset(0.25, 0)),
      Arrowhead._('closed circle', 'Circle', [InkPath.oval(box)], const Offset(0.5, _half)),
      Arrowhead._('closed square', 'Square', [InkPath.rect(box.deflate(0.5))], const Offset(1, _half)),
      Arrowhead._('closed diamond', 'Diamond', [_poly(diamond(1))], const Offset(1, _half)),
      Arrowhead._('open circle', 'Open circle', [InkPath.oval(box), InkPath.oval(box.deflate(1))], const Offset(0.25, _half),
          const Offset(0.25, 0)),
      Arrowhead._('open square', 'Open square', [InkPath.rect(box.deflate(0.5)), InkPath.rect(box.deflate(1.5))],
          const Offset(0.75, _half), const Offset(0.25, 0)),
      Arrowhead._('open diamond', 'Open diamond', openDiamond, diamondTip, const Offset(0.25, 0)),
    ];
  }
}

/// Where a path's arrowheads go, and the trimmed line between them.
/// Ported from -[WDPath computeStrokePathRef].
class ArrowLayout {
  final Arrowhead? start, end;
  final (Offset, double)? startAt, endAt;

  /// The line, shortened so it ends where the arrowheads attach.
  final List<BezierNode> line;

  ArrowLayout._(this.start, this.end, this.startAt, this.endAt, this.line);

  /// Null if the stroke has no arrowheads, or the path is too short to fit
  /// them (then the plain stroke is drawn, as in Inkpad).
  static ArrowLayout? of(InkPath path, StrokeStyle stroke) {
    final start = Arrowhead.named(stroke.startArrow), end = Arrowhead.named(stroke.endArrow);
    if ((start == null && end == null) || path.nodes.length < 2) return null;
    final butt = stroke.cap == LineCap.butt;
    var nodes = [...path.nodes, if (path.closed) path.nodes.first];
    (Offset, double)? startAt, endAt;
    if (start != null) {
      final r = _inset(nodes, start.insetLength(butt) * stroke.width);
      if (r == null) return null;
      (nodes, startAt) = r;
    }
    if (end != null) {
      final r = _inset([for (final n in nodes.reversed) n.flipped()], end.insetLength(butt) * stroke.width);
      if (r == null) return null;
      endAt = r.$2;
      nodes = [for (final n in r.$1.reversed) n.flipped()];
    }
    return ArrowLayout._(start, end, startAt, endAt, nodes);
  }

  /// Cuts the start of [nodes] back to the first point [distance] away
  /// from the first anchor (in a straight line). Returns the remaining
  /// nodes and the attachment point with the arrow's direction.
  /// Ported from -[WDPath insetForArrowhead:nodes:attachment:angle:].
  static (List<BezierNode>, (Offset, double))? _inset(List<BezierNode> nodes, double distance) {
    final tip = nodes.first.anchorPoint;
    for (var i = 0; i < nodes.length - 1; i++) {
      final seg = BezierSegment.between(nodes[i], nodes[i + 1]);
      final t = _firstAtDistance(seg, tip, distance);
      if (t == null) continue;
      final (_, right) = seg.splitAt(t);
      final at = right.a;
      final rest = [
        BezierNode(at, at, right.outA),
        BezierNode(right.inB, nodes[i + 1].anchorPoint, nodes[i + 1].outPoint),
        ...nodes.skip(i + 2),
      ];
      final d = tip - at;
      return (rest, (at, math.atan2(d.dy, d.dx)));
    }
    return null;
  }

  /// The first t where [seg] is [distance] from [p], or null if it never
  /// gets that far.
  static double? _firstAtDistance(BezierSegment seg, Offset p, double distance) {
    const samples = 64;
    var prev = 0.0;
    if ((seg.pointAt(0) - p).distance >= distance) return 0;
    for (var i = 1; i <= samples; i++) {
      final t = i / samples;
      if ((seg.pointAt(t) - p).distance >= distance) {
        var lo = prev, hi = t;
        for (var k = 0; k < 30; k++) {
          final mid = (lo + hi) / 2;
          if ((seg.pointAt(mid) - p).distance >= distance) {
            hi = mid;
          } else {
            lo = mid;
          }
        }
        return hi;
      }
      prev = t;
    }
    return null;
  }

  /// The trimmed line as a flutter path.
  Path linePath() {
    final p = Path()..moveTo(line.first.anchorPoint.dx, line.first.anchorPoint.dy);
    for (var i = 0; i < line.length - 1; i++) {
      final s = BezierSegment.between(line[i], line[i + 1]);
      if (s.isStraight) {
        p.lineTo(s.b.dx, s.b.dy);
      } else {
        p.cubicTo(s.outA.dx, s.outA.dy, s.inB.dx, s.inB.dy, s.b.dx, s.b.dy);
      }
    }
    return p;
  }

  /// Both arrowheads' outlines in the document.
  List<InkPath> arrowOutlines(StrokeStyle stroke) {
    final butt = stroke.cap == LineCap.butt;
    return [
      if (start != null) ...start!.placed(startAt!.$1, stroke.width, startAt!.$2, butt),
      if (end != null) ...end!.placed(endAt!.$1, stroke.width, endAt!.$2, butt),
    ];
  }

  /// Both arrowheads as one flutter path.
  Path arrowsPath(StrokeStyle stroke) {
    final p = Path()..fillType = PathFillType.evenOdd;
    for (final c in arrowOutlines(stroke)) {
      p.addPath(c.toFlutterPath(), Offset.zero);
    }
    return p;
  }

  Rect arrowBounds(StrokeStyle stroke) =>
      arrowOutlines(stroke).map((c) => c.bounds).fold<Rect?>(null, (a, b) => a == null ? b : a.expandToInclude(b)) ?? Rect.zero;
}
