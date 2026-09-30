import 'dart:math' as math;
import 'dart:ui';

import 'bezier_node.dart';
import 'geometry.dart';
import 'style.dart';

/// Base class for everything that lives on a layer. Ported from WDElement.
abstract class InkElement {
  double opacity;

  InkElement({this.opacity = 1});

  /// Geometric bounds, ignoring stroke width.
  Rect get bounds;

  /// Bounds including stroke (what actually gets painted).
  Rect get styleBounds => bounds;

  void render(Canvas canvas);

  void transform(Affine t);

  /// True if [pt] hits this element, with [tolerance] in document units.
  bool hitTest(Offset pt, double tolerance);

  bool intersectsRect(Rect r) => bounds.overlaps(r);

  /// The SVG markup for this element.
  String toSvg();

  InkElement clone() => InkElement.fromJson(toJson());

  Map<String, dynamic> toJson();

  static InkElement fromJson(Map<String, dynamic> j) => switch (j['type']) {
        'path' => InkPath.fromJson(j),
        'group' => InkGroup.fromJson(j),
        _ => throw FormatException('Unknown element type ${j['type']}'),
      };

  String opacityAttr() => opacity < 1 ? ' opacity="${fmt(opacity)}"' : '';
}

/// A single bezier path. Ported from WDPath (compound paths come later).
class InkPath extends InkElement {
  List<BezierNode> nodes;
  bool closed;
  InkColor? fill;
  StrokeStyle? stroke;

  InkPath({
    List<BezierNode>? nodes,
    this.closed = false,
    this.fill,
    this.stroke,
    super.opacity,
  }) : nodes = nodes ?? [];

  factory InkPath.rect(Rect r) => InkPath(
        nodes: [
          BezierNode.anchor(r.topLeft),
          BezierNode.anchor(r.topRight),
          BezierNode.anchor(r.bottomRight),
          BezierNode.anchor(r.bottomLeft),
        ],
        closed: true,
      );

  /// Four-node oval, same construction as Inkpad's pathWithOvalInRect.
  factory InkPath.oval(Rect r) {
    const kappa = 0.5522847498;
    final c = r.center;
    final hx = r.width / 2 * kappa, hy = r.height / 2 * kappa;
    return InkPath(
      nodes: [
        BezierNode(Offset(r.left, c.dy + hy), Offset(r.left, c.dy), Offset(r.left, c.dy - hy)),
        BezierNode(Offset(c.dx - hx, r.top), Offset(c.dx, r.top), Offset(c.dx + hx, r.top)),
        BezierNode(Offset(r.right, c.dy - hy), Offset(r.right, c.dy), Offset(r.right, c.dy + hy)),
        BezierNode(Offset(c.dx + hx, r.bottom), Offset(c.dx, r.bottom), Offset(c.dx - hx, r.bottom)),
      ],
      closed: true,
    );
  }

  /// Regular polygon or star with [points] tips.
  factory InkPath.star(Rect r, int points, {double innerRatio = 0.5}) {
    final c = r.center;
    final nodes = <BezierNode>[];
    final count = points * 2;
    for (var i = 0; i < count; i++) {
      final angle = -math.pi / 2 + i * math.pi / points;
      final ratio = i.isEven ? 1.0 : innerRatio;
      nodes.add(BezierNode.anchor(Offset(
        c.dx + math.cos(angle) * r.width / 2 * ratio,
        c.dy + math.sin(angle) * r.height / 2 * ratio,
      )));
    }
    return InkPath(nodes: nodes, closed: true);
  }

  Iterable<BezierSegment> get segments sync* {
    for (var i = 0; i + 1 < nodes.length; i++) {
      yield BezierSegment.between(nodes[i], nodes[i + 1]);
    }
    if (closed && nodes.length > 1) {
      yield BezierSegment.between(nodes.last, nodes.first);
    }
  }

  Path toFlutterPath() {
    final p = Path();
    if (nodes.isEmpty) return p;
    p.moveTo(nodes.first.anchorPoint.dx, nodes.first.anchorPoint.dy);
    for (final s in segments) {
      if (s.isStraight) {
        p.lineTo(s.b.dx, s.b.dy);
      } else {
        p.cubicTo(s.outA.dx, s.outA.dy, s.inB.dx, s.inB.dy, s.b.dx, s.b.dy);
      }
    }
    if (closed) p.close();
    return p;
  }

  @override
  Rect get bounds {
    if (nodes.isEmpty) return Rect.zero;
    if (nodes.length == 1) return Rect.fromCenter(center: nodes.first.anchorPoint, width: 0, height: 0);
    return toFlutterPath().getBounds();
  }

  @override
  Rect get styleBounds {
    final s = stroke;
    return s != null && s.willRender ? bounds.inflate(s.width / 2) : bounds;
  }

  /// Control-point bounds (includes handles).
  Rect get controlBounds {
    Rect? r;
    for (final n in nodes) {
      r = unionRects(r, rectFromPoints(n.inPoint, n.outPoint));
      r = unionRects(r, Rect.fromCenter(center: n.anchorPoint, width: 0, height: 0));
    }
    return r ?? Rect.zero;
  }

  @override
  void render(Canvas canvas) {
    if (nodes.isEmpty) return;
    final path = toFlutterPath();
    final f = fill;
    if (f != null) {
      canvas.drawPath(path, Paint()..color = f.toColor(opacity));
    }
    final s = stroke;
    if (s != null && s.willRender) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = s.color.toColor(opacity)
          ..strokeWidth = s.width
          ..strokeCap = s.flutterCap
          ..strokeJoin = s.flutterJoin,
      );
    }
  }

  @override
  void transform(Affine t) {
    // Like Inkpad, stroke width is left unchanged by transforms.
    nodes = nodes.map((n) => n.transform(t)).toList();
  }

  @override
  bool hitTest(Offset pt, double tolerance) {
    if (!styleBounds.inflate(tolerance).contains(pt)) return false;
    if (fill != null && toFlutterPath().contains(pt)) return true;
    final strokeSlop = (stroke?.width ?? 0) / 2 + tolerance;
    for (final s in segments) {
      if (s.closestPoint(pt, samples: 16).$1 <= strokeSlop) return true;
    }
    return false;
  }

  @override
  bool intersectsRect(Rect r) {
    if (!bounds.overlaps(r)) return false;
    for (final n in nodes) {
      if (r.contains(n.anchorPoint)) return true;
    }
    for (final s in segments) {
      for (var i = 0; i <= 16; i++) {
        if (r.contains(s.pointAt(i / 16))) return true;
      }
    }
    return false;
  }

  /// Ported from -[WDPath nodeSVGRepresentation].
  String get svgPathData {
    if (nodes.isEmpty) return '';
    final sb = StringBuffer();
    final a = nodes.first.anchorPoint;
    sb.write('M${fmt(a.dx)} ${fmt(a.dy)}');
    for (final s in segments) {
      if (s.isStraight) {
        sb.write('L${fmt(s.b.dx)} ${fmt(s.b.dy)}');
      } else {
        sb.write('C${fmt(s.outA.dx)} ${fmt(s.outA.dy)} '
            '${fmt(s.inB.dx)} ${fmt(s.inB.dy)} '
            '${fmt(s.b.dx)} ${fmt(s.b.dy)}');
      }
    }
    if (closed) sb.write('Z');
    return sb.toString();
  }

  @override
  String toSvg() {
    final attrs = <String, String>{'d': svgPathData};
    final f = fill;
    if (f != null) {
      attrs['fill'] = f.hexValue;
      if (f.alpha != 1) attrs['fill-opacity'] = fmt(f.alpha);
    } else {
      attrs['fill'] = 'none';
    }
    final s = stroke;
    if (s != null && s.willRender) attrs.addAll(s.svgAttributes());
    final a = attrs.entries.map((e) => '${e.key}="${e.value}"').join(' ');
    return '<path $a${opacityAttr()}/>';
  }

  /// Inserts an anchor at parameter [t] of segment [segmentIndex], keeping
  /// the curve shape unchanged. Ported from -[WDPath addAnchorAtPoint:].
  void insertAnchor(int segmentIndex, double t) {
    final seg = segments.elementAt(segmentIndex);
    if (seg.isStraight) {
      // Keep straight segments straight, with no handles on the new point.
      nodes.insert(segmentIndex + 1, BezierNode.anchor(seg.pointAt(t)));
      return;
    }
    final (left, right) = seg.splitAt(t);
    final i0 = segmentIndex, i1 = (segmentIndex + 1) % nodes.length;
    final n0 = nodes[i0], n1 = nodes[i1];
    nodes[i0] = BezierNode(n0.inPoint, n0.anchorPoint, left.outA);
    nodes[i1] = BezierNode(right.inB, n1.anchorPoint, n1.outPoint);
    nodes.insert(segmentIndex + 1, BezierNode(left.inB, left.b, right.outA));
  }

  /// Index of the anchor within [tolerance] of [pt], or null.
  int? anchorIndexAt(Offset pt, double tolerance) {
    for (var i = 0; i < nodes.length; i++) {
      if ((nodes[i].anchorPoint - pt).distance <= tolerance) return i;
    }
    return null;
  }

  /// The segment index and curve parameter of the edge point closest to
  /// [pt], if it is within [tolerance].
  (int, double)? edgeHit(Offset pt, double tolerance) {
    (int, double)? best;
    var bestD = tolerance;
    for (final (i, s) in segments.indexed) {
      final (d, t) = s.closestPoint(pt);
      if (d <= bestD) {
        bestD = d;
        best = (i, t);
      }
    }
    return best;
  }

  /// Removes the anchor at [index]. Like Inkpad, a path keeps at least
  /// two anchors. Returns false if the anchor couldn't be removed.
  bool deleteAnchor(int index) {
    if (nodes.length <= 2) return false;
    nodes.removeAt(index);
    return true;
  }

  /// Toggles an anchor between corner and smooth.
  /// Ported from -[WDPath convertNode:whichPoint:]: a node with handles loses
  /// them; a node without handles gets smooth handles parallel to the line
  /// between its neighbours, a quarter of that distance long.
  void convertAnchor(int index) {
    final node = nodes[index];
    if (node.hasInPoint || node.hasOutPoint) {
      nodes[index] = node.chopHandles();
      return;
    }
    final wrap = closed && nodes.length > 2;
    final prev = index > 0 ? nodes[index - 1] : (wrap ? nodes.last : node);
    final next = index < nodes.length - 1 ? nodes[index + 1] : (wrap ? nodes.first : node);
    final v = next.anchorPoint - prev.anchorPoint;
    final handle = normalize(v) * (v.distance / 4);
    nodes[index] = BezierNode(node.anchorPoint - handle, node.anchorPoint, node.anchorPoint + handle);
  }

  void reverse() {
    nodes = nodes.reversed.map((n) => n.flipped()).toList();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'path',
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'closed': closed,
        'fill': fill?.toJson(),
        'stroke': stroke?.toJson(),
        'opacity': opacity,
      };

  factory InkPath.fromJson(Map<String, dynamic> j) => InkPath(
        nodes: (j['nodes'] as List).map((n) => BezierNode.fromJson(n)).toList(),
        closed: j['closed'] as bool,
        fill: j['fill'] == null ? null : InkColor.fromJson(j['fill']),
        stroke: j['stroke'] == null ? null : StrokeStyle.fromJson(j['stroke']),
        opacity: (j['opacity'] as num).toDouble(),
      );
}

/// A group of elements. Ported from WDGroup.
class InkGroup extends InkElement {
  List<InkElement> elements;

  InkGroup(this.elements, {super.opacity});

  @override
  Rect get bounds => elements.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));

  @override
  Rect get styleBounds =>
      elements.map((e) => e.styleBounds).reduce((a, b) => a.expandToInclude(b));

  @override
  void render(Canvas canvas) {
    if (opacity < 1) {
      canvas.saveLayer(styleBounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
      for (final e in elements) {
        e.render(canvas);
      }
      canvas.restore();
    } else {
      for (final e in elements) {
        e.render(canvas);
      }
    }
  }

  @override
  void transform(Affine t) {
    for (final e in elements) {
      e.transform(t);
    }
  }

  @override
  bool hitTest(Offset pt, double tolerance) => elements.any((e) => e.hitTest(pt, tolerance));

  @override
  bool intersectsRect(Rect r) => elements.any((e) => e.intersectsRect(r));

  @override
  String toSvg() => '<g${opacityAttr()}>${elements.map((e) => e.toSvg()).join()}</g>';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'group',
        'elements': elements.map((e) => e.toJson()).toList(),
        'opacity': opacity,
      };

  factory InkGroup.fromJson(Map<String, dynamic> j) => InkGroup(
        (j['elements'] as List).map((e) => InkElement.fromJson(e)).toList(),
        opacity: (j['opacity'] as num).toDouble(),
      );
}
