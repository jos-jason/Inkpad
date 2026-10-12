import 'dart:math' as math;
import 'dart:ui';

import '../geometry/arrowheads.dart';
import 'bezier_node.dart';
import 'effects.dart';
import 'geometry.dart';
import 'image.dart';
import 'style.dart';
import 'text.dart';

export 'effects.dart';
export 'image.dart';
export 'text.dart';

/// Base class for everything that lives on a layer. Ported from WDElement.
abstract class InkElement {
  double opacity;

  /// A drop shadow (null for none) and blend mode, applied to the element
  /// as a whole, as Inkpad's transparency layers did.
  InkShadow? shadow;
  InkBlendMode blendMode;

  InkElement({this.opacity = 1, this.shadow, this.blendMode = InkBlendMode.normal});

  /// Geometric bounds, ignoring stroke width.
  Rect get bounds;

  /// Bounds including stroke (what actually gets painted).
  Rect get styleBounds => bounds;

  /// Everything painted, including the shadow.
  Rect get paintBounds {
    final s = shadow;
    if (s == null) return styleBounds;
    final b = styleBounds;
    return b.expandToInclude(b.shift(s.displacement).inflate(s.radius * 1.5));
  }

  /// Draws the element with its shadow and blend mode.
  void render(Canvas canvas) {
    final s = shadow;
    if (s == null && blendMode == InkBlendMode.normal) return renderElement(canvas);
    final blended = blendMode != InkBlendMode.normal;
    if (blended) canvas.saveLayer(paintBounds, Paint()..blendMode = blendMode.flutter);
    if (s != null) s.paint(canvas, styleBounds, () => renderElement(canvas));
    renderElement(canvas);
    if (blended) canvas.restore();
  }

  /// Draws the element itself (no shadow or blend mode).
  void renderElement(Canvas canvas);

  void transform(Affine t);

  /// True if [pt] hits this element, with [tolerance] in document units.
  bool hitTest(Offset pt, double tolerance);

  bool intersectsRect(Rect r) => bounds.overlaps(r);

  /// The SVG markup for this element; gradients and clip paths it needs are
  /// added to [w]'s definitions.
  String toSvg(SvgWriter w) {
    final svg = elementSvg(w);
    final s = shadow;
    if (s == null && blendMode == InkBlendMode.normal) return svg;
    final attrs = StringBuffer();
    if (s != null) attrs.write(' filter="url(#${w.shadow(s)})"');
    if (blendMode != InkBlendMode.normal) attrs.write(' style="mix-blend-mode:${blendMode.css}"');
    return '<g$attrs>$svg</g>';
  }

  /// The SVG for the element itself (no shadow or blend mode).
  String elementSvg(SvgWriter w);

  InkElement clone() => InkElement.fromJson(toJson());

  /// This element, then everything inside it (group members, masked elements).
  Iterable<InkElement> get selfAndDescendants sync* {
    yield this;
  }

  Map<String, dynamic> toJson();

  static InkElement fromJson(Map<String, dynamic> j) => switch (j['type']) {
        'path' => InkPath.fromJson(j),
        'compound' => InkCompoundPath.fromJson(j),
        'group' => InkGroup.fromJson(j),
        'image' => InkImage.fromJson(j),
        'text' => InkText.fromJson(j),
        'textPath' => InkTextPath.fromJson(j),
        _ => throw FormatException('Unknown element type ${j['type']}'),
      };

  String opacityAttr() => opacity < 1 ? ' opacity="${fmt(opacity)}"' : '';

  /// Takes opacity, shadow and blend mode from [other].
  void copyEffects(InkElement other) {
    opacity = other.opacity;
    shadow = other.shadow;
    blendMode = other.blendMode;
  }

  /// JSON for opacity, shadow and blend mode.
  Map<String, dynamic> effectsJson() => {
        'opacity': opacity,
        if (shadow != null) 'shadow': shadow!.toJson(),
        if (blendMode != InkBlendMode.normal) 'blend': blendMode.name,
      };

  void readEffectsJson(Map<String, dynamic> j) {
    opacity = (j['opacity'] as num?)?.toDouble() ?? 1;
    shadow = j['shadow'] == null ? null : InkShadow.fromJson(j['shadow']);
    blendMode = InkBlendMode.values.asNameMap()[j['blend']] ?? InkBlendMode.normal;
  }
}

/// Collects the `<defs>` (gradients, clip paths) while a drawing is exported.
class SvgWriter {
  final List<String> definitions = [];
  int _gradients = 0, _clips = 0, _shadows = 0;

  /// Adds a drop shadow filter; returns its id.
  String shadow(InkShadow s) {
    final id = 'shadow${++_shadows}';
    definitions.add(s.svgFilter(id));
    return id;
  }

  final Map<String, String> _images = {};

  /// Adds an image's data once, however often it's used (as Inkpad did);
  /// returns its id.
  String image(ImageData data) => _images.putIfAbsent(data.id, () {
        final id = 'image${_images.length + 1}';
        definitions.add('<image id="$id" width="${data.width}" height="${data.height}" '
            'preserveAspectRatio="none" xlink:href="${data.dataUri}"/>');
        return id;
      });

  /// Adds a gradient definition for a shape with [bounds]; returns its id.
  String gradient(InkGradient g, Rect bounds) {
    final id = 'gradient${++_gradients}';
    definitions.add(g.svgDefinition(id, bounds));
    return id;
  }

  int _textPaths = 0;

  /// Adds a path for `<textPath>` to follow; returns its id.
  String textPath(InkPath guide) {
    final id = 'textpath${++_textPaths}';
    definitions.add('<path id="$id" d="${guide.svgPathData}"/>');
    return id;
  }

  /// Adds a `<clipPath>` with [shape]'s outline; returns its id.
  String clipPath(InkStylable shape) {
    final id = 'clip${++_clips}';
    final rule = shape.fillRule == FillRule.evenOdd ? ' clip-rule="evenodd"' : '';
    definitions.add('<clipPath id="$id"><path d="${shape.svgPathData}"$rule/></clipPath>');
    return id;
  }
}

enum FillRule { nonZero, evenOdd }

/// An element with a fill and stroke, drawn from bezier geometry.
/// Ported from WDStylable / WDAbstractPath.
///
/// Like Inkpad, any stylable can be a clipping mask: [maskedElements] are
/// drawn clipped to its outline, above its own fill and below its stroke.
abstract class InkStylable extends InkElement {
  InkPaint? fill;
  StrokeStyle? stroke;
  FillRule fillRule;
  List<InkElement> maskedElements;

  InkStylable({this.fill, this.stroke, this.fillRule = FillRule.nonZero, List<InkElement>? maskedElements, super.opacity})
      : maskedElements = maskedElements ?? [];

  bool get isMasking => maskedElements.isNotEmpty;

  @override
  Iterable<InkElement> get selfAndDescendants sync* {
    yield this;
    for (final e in maskedElements) {
      yield* e.selfAndDescendants;
    }
  }

  /// Applies [t] to the outline only.
  void transformGeometry(Affine t);

  @override
  void transform(Affine t) {
    // A fitted gradient becomes explicit so it turns and stretches with the
    // shape, as Inkpad's fill transform did.
    final f = fill;
    if (f is InkGradient) fill = f.copyWith(geometry: f.fitted(bounds).transformed(t));
    transformGeometry(t);
    for (final e in maskedElements) {
      e.transform(t);
    }
  }

  Path toFlutterPath();

  /// Every bezier segment, across all subpaths.
  Iterable<BezierSegment> get allSegments;

  bool get isEmpty;

  /// The SVG `d` attribute.
  String get svgPathData;

  @override
  Rect get bounds => isEmpty ? Rect.zero : toFlutterPath().getBounds();

  @override
  Rect get styleBounds {
    final s = stroke;
    return s != null && s.willRender ? bounds.inflate(s.width / 2) : bounds;
  }

  @override
  void renderElement(Canvas canvas) {
    if (isEmpty) return;
    // A mask's opacity applies to it and its contents as a whole.
    if (isMasking && opacity < 1) {
      canvas.saveLayer(styleBounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
      _renderContents(canvas, 1);
      canvas.restore();
    } else {
      _renderContents(canvas, opacity);
    }
  }

  /// A paint for the fill, or null if there is none.
  Paint? fillPaint(double opacity) {
    final f = fill;
    if (f == null) return null;
    if (f is InkGradient) {
      final shader = f.shader(bounds, opacity);
      return shader == null ? (Paint()..color = f.stops.last.color.toColor(opacity)) : (Paint()..shader = shader);
    }
    return Paint()..color = (f as InkColor).toColor(opacity);
  }

  void _renderContents(Canvas canvas, double opacity) {
    final path = toFlutterPath();
    final paint = fillPaint(opacity);
    if (paint != null) canvas.drawPath(path, paint);
    if (isMasking) {
      canvas.save();
      canvas.clipPath(path);
      for (final e in maskedElements) {
        e.render(canvas);
      }
      canvas.restore();
    }
    final s = stroke;
    if (s != null && s.willRender) {
      final arrows = this is InkPath ? (this as InkPath).arrowLayout : null;
      final line = arrows?.linePath() ?? path;
      // With arrowheads, line and arrows are drawn as one: a see-through
      // stroke doesn't darken where they overlap (as in Inkpad).
      final alpha = s.color.alpha * opacity;
      final unify = arrows != null && alpha < 1;
      if (unify) canvas.saveLayer(styleBounds.inflate(1), Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      final color = unify ? s.color.withAlpha(1).toColor() : s.color.toColor(opacity);
      canvas.drawPath(
        s.dashPattern.isEmpty ? line : dashPath(line, s.dashPattern),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = color
          ..strokeWidth = s.width
          ..strokeCap = s.flutterCap
          ..strokeJoin = s.flutterJoin,
      );
      if (arrows != null) canvas.drawPath(arrows.arrowsPath(s), Paint()..color = color);
      if (unify) canvas.restore();
    }
  }

  @override
  bool hitTest(Offset pt, double tolerance) {
    if (!styleBounds.inflate(tolerance).contains(pt)) return false;
    if ((fill != null || isMasking) && toFlutterPath().contains(pt)) {
      if (fill != null) return true;
      // Through an unfilled mask, only the visible contents count.
      if (maskedElements.any((e) => e.hitTest(pt, tolerance))) return true;
    }
    final strokeSlop = (stroke?.width ?? 0) / 2 + tolerance;
    for (final s in allSegments) {
      if (s.closestPoint(pt, samples: 16).$1 <= strokeSlop) return true;
    }
    return false;
  }

  @override
  bool intersectsRect(Rect r) {
    if (!bounds.overlaps(r)) return false;
    if (isMasking && maskedElements.any((e) => e.intersectsRect(r))) return true;
    for (final s in allSegments) {
      for (var i = 0; i <= 16; i++) {
        if (r.contains(s.pointAt(i / 16))) return true;
      }
    }
    return false;
  }

  @override
  String elementSvg(SvgWriter w) {
    if (!isMasking) return _pathSvg(w, fill: true, stroke: true, opacity: true);
    // A mask: its fill, then the clipped contents, then its stroke.
    final clip = w.clipPath(this);
    final contents = maskedElements.map((e) => e.toSvg(w)).join();
    final parts = [
      if (fill != null) _pathSvg(w, fill: true, stroke: false, opacity: false),
      '<g clip-path="url(#$clip)">$contents</g>',
      if (stroke?.willRender ?? false) _pathSvg(w, fill: false, stroke: true, opacity: false),
    ];
    if (parts.length == 1 && opacity == 1) return parts.single;
    return '<g${opacityAttr()}>${parts.join()}</g>';
  }

  String _pathSvg(SvgWriter w, {required bool fill, required bool stroke, required bool opacity}) {
    final attrs = <String, String>{'d': svgPathData};
    final f = fill ? this.fill : null;
    if (f is InkGradient) {
      attrs['fill'] = 'url(#${w.gradient(f, bounds)})';
    } else if (f is InkColor) {
      attrs['fill'] = f.hexValue;
      if (f.alpha != 1) attrs['fill-opacity'] = fmt(f.alpha);
    } else {
      attrs['fill'] = 'none';
    }
    if (fillRule == FillRule.evenOdd) attrs['fill-rule'] = 'evenodd';
    final s = stroke ? this.stroke : null;
    if (s != null && s.willRender) attrs.addAll(s.svgAttributes());
    final a = attrs.entries.map((e) => '${e.key}="${e.value}"').join(' ');
    return '<path $a${opacity ? opacityAttr() : ''}/>';
  }

  Map<String, dynamic> styleJson() => {
        'fill': fill?.toJson(),
        'stroke': stroke?.toJson(),
        if (fillRule == FillRule.evenOdd) 'fillRule': 'evenOdd',
        ...effectsJson(),
        if (isMasking) 'masked': maskedElements.map((e) => e.toJson()).toList(),
      };

  void readStyleJson(Map<String, dynamic> j) {
    fill = j['fill'] == null ? null : InkPaint.fromJson(j['fill']);
    maskedElements = [for (final e in (j['masked'] as List?) ?? const []) InkElement.fromJson(e)];
    stroke = j['stroke'] == null ? null : StrokeStyle.fromJson(j['stroke']);
    fillRule = j['fillRule'] == 'evenOdd' ? FillRule.evenOdd : FillRule.nonZero;
    readEffectsJson(j);
  }
}

/// Splits [source] into dashes following an SVG-style dash [pattern].
Path dashPath(Path source, List<double> pattern) {
  final total = pattern.fold<double>(0, (a, b) => a + b);
  if (total <= 0) return source;
  final out = Path();
  for (final metric in source.computeMetrics()) {
    var distance = 0.0, i = 0;
    var draw = true;
    while (distance < metric.length) {
      final len = pattern[i % pattern.length];
      if (draw && len > 0) out.addPath(metric.extractPath(distance, distance + len), Offset.zero);
      distance += len;
      draw = !draw;
      i++;
      if (i > 100000) break; // guards against pathological patterns
    }
  }
  return out;
}

/// A single bezier path. Ported from WDPath.
class InkPath extends InkStylable {
  List<BezierNode> nodes;
  bool closed;

  InkPath({
    List<BezierNode>? nodes,
    this.closed = false,
    super.fill,
    super.stroke,
    super.fillRule,
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

  /// Ported from +[WDPath pathWithRoundedRect:cornerRadius:], with separate
  /// horizontal and vertical radii (as SVG allows).
  factory InkPath.roundedRect(Rect r, double rx, [double? ry]) {
    ry ??= rx;
    rx = rx.clamp(0.0, r.width / 2);
    ry = ry.clamp(0.0, r.height / 2);
    if (rx <= 0 || ry <= 0) return InkPath.rect(r);
    const k = 0.5522847498;
    final kx = rx * k, ky = ry * k;
    BezierNode node(double ix, double iy, double ax, double ay, double ox, double oy) =>
        BezierNode(Offset(ix, iy), Offset(ax, ay), Offset(ox, oy));
    final l = r.left, t = r.top, rt = r.right, b = r.bottom;
    return InkPath(closed: true, nodes: [
      node(l + rx - kx, t, l + rx, t, l + rx, t),
      node(rt - rx, t, rt - rx, t, rt - rx + kx, t),
      node(rt, t + ry - ky, rt, t + ry, rt, t + ry),
      node(rt, b - ry, rt, b - ry, rt, b - ry + ky),
      node(rt - rx + kx, b, rt - rx, b, rt - rx, b),
      node(l + rx, b, l + rx, b, l + rx - kx, b),
      node(l, b - ry + ky, l, b - ry, l, b - ry),
      node(l, t + ry, l, t + ry, l, t + ry - ky),
    ]);
  }

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

  @override
  Iterable<BezierSegment> get allSegments => segments;

  @override
  bool get isEmpty => nodes.isEmpty;

  /// Adds this path's outline to [p] as a new subpath.
  void addTo(Path p) {
    if (nodes.isEmpty) return;
    p.moveTo(nodes.first.anchorPoint.dx, nodes.first.anchorPoint.dy);
    for (final s in segments) {
      if (s.isStraight) {
        p.lineTo(s.b.dx, s.b.dy);
      } else {
        p.cubicTo(s.outA.dx, s.outA.dy, s.inB.dx, s.inB.dy, s.b.dx, s.b.dy);
      }
    }
    if (closed) p.close();
  }

  @override
  Path toFlutterPath() {
    final p = Path()..fillType = fillRule == FillRule.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
    addTo(p);
    return p;
  }

  @override
  Rect get bounds {
    if (nodes.length == 1) return Rect.fromCenter(center: nodes.first.anchorPoint, width: 0, height: 0);
    return super.bounds;
  }

  /// Control-point bounds (includes handles).
  ArrowLayout? _arrows;
  Object? _arrowsKey;

  /// Where this path's arrowheads go (null if it has none, or they don't fit).
  ArrowLayout? get arrowLayout {
    final s = stroke;
    if (s == null || !s.hasArrows || !s.willRender) return null;
    final key = (Object.hashAll(nodes), closed, s.width, s.cap, s.startArrow, s.endArrow);
    if (key != _arrowsKey) {
      _arrowsKey = key;
      _arrows = ArrowLayout.of(this, s);
    }
    return _arrows;
  }

  @override
  Rect get styleBounds {
    final a = arrowLayout;
    return a == null ? super.styleBounds : super.styleBounds.expandToInclude(a.arrowBounds(stroke!));
  }

  @override
  bool hitTest(Offset pt, double tolerance) {
    if (super.hitTest(pt, tolerance)) return true;
    final a = arrowLayout;
    return a != null && a.arrowsPath(stroke!).contains(pt);
  }

  /// With arrowheads, a group as Inkpad wrote it: the shape's fill, the
  /// trimmed line and the arrowheads. The inkpad: attributes let it be read
  /// back as one path.
  @override
  String elementSvg(SvgWriter w) {
    final a = arrowLayout;
    final s = stroke;
    if (a == null || s == null || isMasking) return super.elementSvg(w);
    final unify = s.color.alpha < 1;
    final color = unify ? s.color.withAlpha(1) : s.color;
    final strokeAttrs = s.copyWith(color: color).svgAttributes().entries.map((e) => ' ${e.key}="${e.value}"').join();
    final line = '<path d="${InkPath(nodes: a.line).svgPathData}" fill="none"$strokeAttrs/>';
    final heads = '<path d="${a.arrowOutlines(s).map((c) => c.svgPathData).join()}" fill="${color.hexValue}" fill-rule="evenodd"/>';
    final strokePart = unify ? '<g opacity="${fmt(s.color.alpha)}">$line$heads</g>' : '$line$heads';
    final ends = [
      if (s.startArrow.isNotEmpty) ' inkpad:start-arrow="${s.startArrow}"',
      if (s.endArrow.isNotEmpty) ' inkpad:end-arrow="${s.endArrow}"',
    ].join();
    return '<g$ends${opacityAttr()}>${_pathSvg(w, fill: true, stroke: false, opacity: false)}$strokePart</g>';
  }

  Rect get controlBounds {
    Rect? r;
    for (final n in nodes) {
      r = unionRects(r, rectFromPoints(n.inPoint, n.outPoint));
      r = unionRects(r, Rect.fromCenter(center: n.anchorPoint, width: 0, height: 0));
    }
    return r ?? Rect.zero;
  }

  @override
  void transformGeometry(Affine t) {
    // Like Inkpad, stroke width is left unchanged by transforms.
    nodes = nodes.map((n) => n.transform(t)).toList();
  }

  @override
  bool intersectsRect(Rect r) =>
      nodes.any((n) => r.contains(n.anchorPoint)) || super.intersectsRect(r);

  /// Ported from -[WDPath nodeSVGRepresentation].
  @override
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
        ...styleJson(),
      };

  factory InkPath.fromJson(Map<String, dynamic> j) => InkPath(
        nodes: (j['nodes'] as List).map((n) => BezierNode.fromJson(n)).toList(),
        closed: j['closed'] as bool,
      )..readStyleJson(j);
}

/// Several subpaths filled and stroked as one shape, so inner subpaths can
/// cut holes (letters, rings). Ported from WDCompoundPath.
class InkCompoundPath extends InkStylable {
  /// Geometry only; the subpaths' own style fields are ignored.
  List<InkPath> subpaths;

  InkCompoundPath(this.subpaths, {super.fill, super.stroke, super.fillRule, super.opacity});

  @override
  Iterable<BezierSegment> get allSegments => subpaths.expand((p) => p.segments);

  @override
  bool get isEmpty => subpaths.every((p) => p.isEmpty);

  @override
  Path toFlutterPath() {
    final p = Path()..fillType = fillRule == FillRule.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
    for (final sub in subpaths) {
      sub.addTo(p);
    }
    return p;
  }

  @override
  void transformGeometry(Affine t) {
    for (final p in subpaths) {
      p.transformGeometry(t);
    }
  }

  @override
  String get svgPathData => subpaths.map((p) => p.svgPathData).join();

  @override
  Map<String, dynamic> toJson() => {
        'type': 'compound',
        'subpaths': [
          for (final p in subpaths) {'nodes': p.nodes.map((n) => n.toJson()).toList(), 'closed': p.closed},
        ],
        ...styleJson(),
      };

  factory InkCompoundPath.fromJson(Map<String, dynamic> j) => InkCompoundPath([
        for (final p in j['subpaths'] as List)
          InkPath(
            nodes: (p['nodes'] as List).map((n) => BezierNode.fromJson(n)).toList(),
            closed: p['closed'] as bool,
          ),
      ])
        ..readStyleJson(j);
}

/// A group of elements. Ported from WDGroup.
class InkGroup extends InkElement {
  List<InkElement> elements;

  InkGroup(this.elements, {super.opacity});

  @override
  Iterable<InkElement> get selfAndDescendants sync* {
    yield this;
    for (final e in elements) {
      yield* e.selfAndDescendants;
    }
  }

  @override
  Rect get bounds => elements.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));

  @override
  Rect get styleBounds =>
      elements.map((e) => e.styleBounds).reduce((a, b) => a.expandToInclude(b));

  @override
  void renderElement(Canvas canvas) {
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
  String elementSvg(SvgWriter w) => '<g${opacityAttr()}>${elements.map((e) => e.toSvg(w)).join()}</g>';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'group',
        'elements': elements.map((e) => e.toJson()).toList(),
        ...effectsJson(),
      };

  factory InkGroup.fromJson(Map<String, dynamic> j) =>
      InkGroup((j['elements'] as List).map((e) => InkElement.fromJson(e)).toList())..readEffectsJson(j);
}
