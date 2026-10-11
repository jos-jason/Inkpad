import 'dart:math' as math;
import 'dart:ui';

import 'package:glyph_path/glyph_path.dart' as gp;

import '../text/font_library.dart';
import 'bezier_node.dart';
import 'element.dart';
import 'geometry.dart';
import 'style.dart';

enum TextAlignment { left, center, right }

/// Font settings shared by text objects and text on paths.
mixin InkTypography on InkStylable {
  String get text;
  String get fontFamily;
  String get fontStyle;
  double get fontSize;

  /// The face to draw with: the requested one once loaded, else the
  /// fallback (and the request starts loading it).
  LoadedFace get face {
    final lib = FontLibrary.instance;
    return lib.face(fontFamily, fontStyle) ?? lib.fallback;
  }

  /// Whether the requested font exists on this device.
  bool get fontAvailable => FontLibrary.instance.has(fontFamily);

  // Outline cache, rebuilt when anything that affects it changes.
  Object? _cacheKey;
  List<InkPath> _outlines = const [];
  Rect _layoutBox = Rect.zero;

  Object get _layoutKey;

  /// Glyph outlines in document space, plus the layout box in text space.
  (List<InkPath>, Rect) buildOutlines();

  List<InkPath> get outlines {
    final f = face;
    final key = (_layoutKey, identityHashCode(f));
    if (key != _cacheKey) {
      final (paths, box) = buildOutlines();
      _outlines = paths;
      _layoutBox = box;
      _cacheKey = key;
    }
    return _outlines;
  }

  Rect get layoutBox {
    outlines;
    return _layoutBox;
  }

  void invalidate() => _cacheKey = null;

  @override
  Iterable<BezierSegment> get allSegments => outlines.expand((p) => p.segments);

  @override
  bool get isEmpty => outlines.every((p) => p.nodes.length < 2);

  @override
  Path toFlutterPath() {
    final p = Path();
    for (final o in outlines) {
      o.addTo(p);
    }
    return p;
  }

  @override
  String get svgPathData => outlines.map((p) => p.svgPathData).join();

  /// The SVG font attributes for this text.
  String svgFontAttrs() {
    final info = FontLibrary.instance.find(fontFamily, fontStyle);
    final weight = info?.weight ?? (fontStyle.toLowerCase().contains('bold') ? 700 : 400);
    final italic = info?.italic ?? fontStyle.toLowerCase().contains('italic');
    return 'font-family="${_xml(fontFamily)}" font-size="${fmt(fontSize)}"'
        '${weight != 400 ? ' font-weight="$weight"' : ''}${italic ? ' font-style="italic"' : ''}';
  }
}

/// Converts glyph_path commands (glyph space, y up) into closed paths, via
/// [map] (which also flips y).
List<InkPath> _contoursToPaths(List<gp.PathCommand> commands, Offset Function(double x, double y) map) {
  final paths = <InkPath>[];
  List<BezierNode>? nodes;
  void finish() {
    if (nodes != null && nodes!.length > 1) {
      // Drop the duplicate end point that closes the contour.
      if ((nodes!.first.anchorPoint - nodes!.last.anchorPoint).distance < 1e-6) {
        final last = nodes!.removeLast();
        nodes![0] = BezierNode(last.inPoint, nodes![0].anchorPoint, nodes![0].outPoint);
      }
      paths.add(InkPath(nodes: nodes, closed: true));
    }
    nodes = null;
  }

  for (final c in commands) {
    switch (c) {
      case gp.MoveTo(:final x, :final y):
        finish();
        nodes = [BezierNode.anchor(map(x, y))];
      case gp.LineTo(:final x, :final y):
        nodes?.add(BezierNode.anchor(map(x, y)));
      case gp.CubicTo(:final control1X, :final control1Y, :final control2X, :final control2Y, :final x, :final y):
        final n = nodes;
        if (n == null) break;
        final last = n.removeLast();
        n.add(BezierNode(last.inPoint, last.anchorPoint, map(control1X, control1Y)));
        n.add(BezierNode(map(control2X, control2Y), map(x, y), map(x, y)));
      case gp.QuadTo(:final controlX, :final controlY, :final x, :final y):
        // Not produced with normalizeToCubic, but handle it anyway.
        final n = nodes;
        if (n == null) break;
        final last = n.removeLast();
        final q = map(controlX, controlY), p = map(x, y);
        n.add(BezierNode(last.inPoint, last.anchorPoint, last.anchorPoint + (q - last.anchorPoint) * (2 / 3)));
        n.add(BezierNode(p + (q - p) * (2 / 3), p, p));
      case gp.ClosePath():
        finish();
    }
  }
  finish();
  return paths;
}

/// A text object. Ported from WDText, plus "point text":
///  * with a [width], area text wrapped to that width, placed by its top-left
///    corner (Inkpad's text);
///  * with no width, point text that doesn't wrap, placed by the start of its
///    first baseline (how SVG text works; made by clicking with the text tool).
class InkText extends InkStylable with InkTypography {
  @override
  String text;
  @override
  String fontFamily;
  @override
  String fontStyle;
  @override
  double fontSize;
  TextAlignment alignment;
  double? width;

  /// Maps text space into the document (moves, scales, rotations).
  Affine placement;

  InkText({
    required this.text,
    required this.fontFamily,
    this.fontStyle = 'Regular',
    this.fontSize = FontLibrary.defaultSize,
    this.alignment = TextAlignment.left,
    this.width,
    this.placement = Affine.identity,
    super.fill,
    super.stroke,
    super.opacity,
  });

  static const minimumWidth = 20.0; // Inkpad's kMinWidth

  @override
  Object get _layoutKey => (text, fontFamily, fontStyle, fontSize, alignment, width, placement);

  /// Lines of text with their baseline and left edge in text space.
  List<({String text, double x, double baseline, double width})> get lines {
    final (layout, scale) = _layout();
    final asc = face.font.ascender * scale;
    final firstBaseline = width == null ? 0.0 : asc;
    return [
      for (final l in layout.lines)
        (
          text: l.glyphs.map((g) => g.sourceText).join(),
          x: _lineX(l),
          baseline: firstBaseline + l.baselineY,
          width: l.lineWidth,
        ),
    ];
  }

  (gp.TextLayoutResult, double) _layout() {
    final f = face.font;
    final layout = gp.TextLayout(f).layout(
      text,
      fontSize: fontSize.clamp(0.1, 10000),
      maxWidth: width,
      alignment: switch (alignment) {
        TextAlignment.left => gp.TextAlign.left,
        TextAlignment.center => gp.TextAlign.center,
        TextAlignment.right => gp.TextAlign.right,
      },
    );
    return (layout, fontSize / f.unitsPerEm);
  }

  /// A line's left edge: from the box's alignment for area text, or around
  /// the anchor point for point text.
  double _lineX(gp.TextLineResult l) {
    if (width != null) return l.alignmentOffset;
    return switch (alignment) {
      TextAlignment.left => 0,
      TextAlignment.center => -l.lineWidth / 2,
      TextAlignment.right => -l.lineWidth,
    };
  }

  @override
  (List<InkPath>, Rect) buildOutlines() {
    if (text.isEmpty) return (const <InkPath>[], _emptyBox());
    final (layout, scale) = _layout();
    final f = face.font;
    final asc = f.ascender * scale, desc = f.descender * scale;
    final firstBaseline = width == null ? 0.0 : asc;
    final paths = <InkPath>[];
    var minX = double.infinity, maxX = -double.infinity;
    for (final line in layout.lines) {
      final baseline = firstBaseline + line.baselineY;
      final x0 = _lineX(line);
      minX = math.min(minX, x0);
      maxX = math.max(maxX, x0 + line.lineWidth);
      for (final g in line.glyphs) {
        final gx = x0 + g.positionX;
        paths.addAll(_contoursToPaths(g.commands, (x, y) => placement.apply(Offset(gx + x, baseline - y))));
      }
    }
    final lastBaseline = firstBaseline + (layout.lines.isEmpty ? 0 : layout.lines.last.baselineY);
    final box = width != null
        ? Rect.fromLTRB(0, 0, width!, lastBaseline - desc)
        : Rect.fromLTRB(minX.isFinite ? minX : 0, -asc, maxX.isFinite ? maxX : 0, lastBaseline - desc);
    return (paths, box);
  }

  Rect _emptyBox() {
    final f = face.font;
    final h = (f.ascender - f.descender) * fontSize / f.unitsPerEm;
    return width != null ? Rect.fromLTWH(0, 0, width!, h) : Rect.fromLTWH(0, -f.ascender * fontSize / f.unitsPerEm, 1, h);
  }

  /// The text box's corners in the document.
  List<Offset> get corners {
    final r = layoutBox;
    return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map(placement.apply).toList();
  }

  @override
  Rect get bounds {
    final c = corners;
    return c.skip(1).fold(Rect.fromPoints(c[0], c[0]), (r, p) => r.expandToInclude(Rect.fromPoints(p, p)));
  }

  /// Text is picked anywhere in its box, which is easier than hitting letters.
  @override
  bool hitTest(Offset pt, double tolerance) =>
      layoutBox.inflate(tolerance / placement.scaleFactor).contains(placement.inverted().apply(pt));

  @override
  bool intersectsRect(Rect r) => bounds.overlaps(r);

  @override
  void transformGeometry(Affine t) => placement = placement.then(t);

  @override
  String toSvg(SvgWriter w) {
    if (isMasking) return super.toSvg(w); // masks export as outlines + clip
    final t = placement;
    final attrs = StringBuffer(' transform="matrix(${[t.a, t.b, t.c, t.d, t.tx, t.ty].map(fmt).join(' ')})"');
    attrs.write(' ${svgFontAttrs()}');
    final f = fill;
    if (f is InkGradient) {
      attrs.write(' fill="url(#${w.gradient(f, bounds)})"');
    } else if (f is InkColor) {
      attrs.write(' fill="${f.hexValue}"');
      if (f.alpha != 1) attrs.write(' fill-opacity="${fmt(f.alpha)}"');
    } else {
      attrs.write(' fill="none"');
    }
    final s = stroke;
    if (s != null && s.willRender) {
      for (final e in s.svgAttributes().entries) {
        attrs.write(' ${e.key}="${e.value}"');
      }
    }
    final anchor = width != null ? 'start' : switch (alignment) { TextAlignment.left => 'start', TextAlignment.center => 'middle', TextAlignment.right => 'end' };
    if (anchor != 'start') attrs.write(' text-anchor="$anchor"');
    if (width != null) {
      // Wrapped lines become separate tspans; keep the typed text so the
      // line breaks you made are known when the file is opened again.
      attrs.write(' inkpad:width="${fmt(width!)}" inkpad:align="${alignment.name}"');
      attrs.write(' inkpad:text="${_xml(text).replaceAll('\n', '&#10;')}"');
    }
    attrs.write(' xml:space="preserve"');
    final spans = [
      for (final l in lines)
        '<tspan x="${fmt(width != null ? l.x : 0)}" y="${fmt(l.baseline)}">${_xml(l.text)}</tspan>',
    ];
    return '<text$attrs${opacityAttr()}>${spans.join()}</text>';
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'text': text,
        'font': fontFamily,
        'fontStyle': fontStyle,
        'size': fontSize,
        'align': alignment.name,
        if (width != null) 'width': width,
        'placement': placement.toJson(),
        ...styleJson(),
      };

  factory InkText.fromJson(Map<String, dynamic> j) => InkText(
        text: j['text'],
        fontFamily: j['font'],
        fontStyle: j['fontStyle'] ?? 'Regular',
        fontSize: (j['size'] as num).toDouble(),
        alignment: TextAlignment.values.byName(j['align'] ?? 'left'),
        width: (j['width'] as num?)?.toDouble(),
        placement: Affine.fromJson(j['placement']),
      )..readStyleJson(j);
}

/// Text that follows a path. Ported from WDTextPath: glyphs sit on the path
/// starting [startOffset] along it; text past the end is hidden.
class InkTextPath extends InkStylable with InkTypography {
  @override
  String text;
  @override
  String fontFamily;
  @override
  String fontStyle;
  @override
  double fontSize;
  double startOffset;

  /// The path the text follows (not drawn itself).
  InkPath guide;

  InkTextPath({
    required this.text,
    required this.guide,
    required this.fontFamily,
    this.fontStyle = 'Regular',
    this.fontSize = FontLibrary.defaultSize,
    this.startOffset = 0,
    super.fill,
    super.stroke,
    super.opacity,
  });

  @override
  Object get _layoutKey => (text, fontFamily, fontStyle, fontSize, startOffset, guide.svgPathData);

  /// The guide flattened, with cumulative lengths, for placing glyphs.
  ({List<Offset> points, List<double> lengths}) get _track {
    final pts = <Offset>[];
    for (final s in guide.segments) {
      final n = s.isStraight ? 1 : 32;
      for (var i = pts.isEmpty ? 0 : 1; i <= n; i++) {
        pts.add(s.pointAt(i / n));
      }
    }
    final lengths = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      lengths.add(lengths.last + (pts[i] - pts[i - 1]).distance);
    }
    return (points: pts, lengths: lengths);
  }

  double get pathLength => _track.lengths.lastOrNull ?? 0;

  /// The point and direction at distance [d] along the guide, or null past
  /// either end.
  (Offset, double)? pointAt(double d, [({List<Offset> points, List<double> lengths})? track]) {
    final t = track ?? _track;
    if (t.points.length < 2 || d < 0 || d > t.lengths.last) return null;
    var i = 1;
    while (i < t.lengths.length - 1 && t.lengths[i] < d) {
      i++;
    }
    final a = t.points[i - 1], b = t.points[i];
    final seg = t.lengths[i] - t.lengths[i - 1];
    final f = seg == 0 ? 0.0 : (d - t.lengths[i - 1]) / seg;
    return (a + (b - a) * f, math.atan2(b.dy - a.dy, b.dx - a.dx));
  }

  /// Distance along the guide of the point nearest [p].
  double offsetNearest(Offset p) {
    final t = _track;
    var best = 0.0, bestD = double.infinity;
    for (var i = 1; i < t.points.length; i++) {
      final a = t.points[i - 1], b = t.points[i];
      final ab = b - a;
      final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
      final f = lenSq == 0 ? 0.0 : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lenSq).clamp(0.0, 1.0);
      final d = (p - (a + ab * f)).distance;
      if (d < bestD) {
        bestD = d;
        best = t.lengths[i - 1] + (t.lengths[i] - t.lengths[i - 1]) * f;
      }
    }
    return best;
  }

  @override
  (List<InkPath>, Rect) buildOutlines() {
    if (text.isEmpty) return (const <InkPath>[], guide.bounds);
    final result = face.font.generateGlyphPaths(text.replaceAll('\n', ' '), fontSize: fontSize.clamp(0.1, 10000));
    final track = _track;
    final paths = <InkPath>[];
    for (final g in result.glyphs) {
      // Place each glyph by its middle, turned to the path's direction there.
      final mid = startOffset + g.positionX + g.advanceWidth / 2;
      final at = pointAt(mid, track);
      if (at == null) continue;
      final (p, angle) = at;
      final cosA = math.cos(angle), sinA = math.sin(angle);
      final half = g.advanceWidth / 2;
      paths.addAll(_contoursToPaths(g.commands, (x, y) {
        final lx = x - half, ly = -y;
        return Offset(p.dx + lx * cosA - ly * sinA, p.dy + lx * sinA + ly * cosA);
      }));
    }
    return (paths, guide.bounds);
  }

  @override
  Rect get bounds {
    final glyphs = isEmpty ? null : toFlutterPath().getBounds();
    return glyphs == null ? guide.bounds : guide.bounds.expandToInclude(glyphs);
  }

  @override
  bool hitTest(Offset pt, double tolerance) =>
      (!isEmpty && toFlutterPath().contains(pt)) || guide.edgeHit(pt, tolerance + fontSize / 4) != null;

  @override
  bool intersectsRect(Rect r) => bounds.overlaps(r);

  @override
  void transformGeometry(Affine t) => guide.transformGeometry(t);

  @override
  String toSvg(SvgWriter w) {
    if (isMasking) return super.toSvg(w);
    final id = w.textPath(guide);
    final attrs = StringBuffer(' ${svgFontAttrs()}');
    final f = fill;
    if (f is InkGradient) {
      attrs.write(' fill="url(#${w.gradient(f, bounds)})"');
    } else if (f is InkColor) {
      attrs.write(' fill="${f.hexValue}"');
      if (f.alpha != 1) attrs.write(' fill-opacity="${fmt(f.alpha)}"');
    } else {
      attrs.write(' fill="none"');
    }
    final s = stroke;
    if (s != null && s.willRender) {
      for (final e in s.svgAttributes().entries) {
        attrs.write(' ${e.key}="${e.value}"');
      }
    }
    return '<text$attrs${opacityAttr()}><textPath xlink:href="#$id" startOffset="${fmt(startOffset)}">'
        '${_xml(text.replaceAll('\n', ' '))}</textPath></text>';
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'textPath',
        'text': text,
        'font': fontFamily,
        'fontStyle': fontStyle,
        'size': fontSize,
        'start': startOffset,
        'guide': {'nodes': guide.nodes.map((n) => n.toJson()).toList(), 'closed': guide.closed},
        ...styleJson(),
      };

  factory InkTextPath.fromJson(Map<String, dynamic> j) => InkTextPath(
        text: j['text'],
        fontFamily: j['font'],
        fontStyle: j['fontStyle'] ?? 'Regular',
        fontSize: (j['size'] as num).toDouble(),
        startOffset: (j['start'] as num).toDouble(),
        guide: InkPath(
          nodes: [for (final n in j['guide']['nodes'] as List) BezierNode.fromJson(n)],
          closed: j['guide']['closed'] as bool,
        ),
      )..readStyleJson(j);
}

String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
