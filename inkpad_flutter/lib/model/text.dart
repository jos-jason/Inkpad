import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:glyph_path/glyph_path.dart' as gp;

import '../text/font_library.dart';
import '../text/rich_layout.dart';
import 'bezier_node.dart';
import 'element.dart';
import 'geometry.dart';
import 'style.dart';

export 'text_runs.dart';

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
  List<InkPaint?>? _outlineFills;
  Rect _layoutBox = Rect.zero;

  Object get _layoutKey;

  /// Glyph outlines in document space, the layout box in text space, and
  /// each outline's own fill where letters are colored differently (null:
  /// all in the text's fill).
  (List<InkPath>, Rect, List<InkPaint?>?) buildOutlines();

  List<InkPath> get outlines {
    final f = face;
    final key = (_layoutKey, identityHashCode(f));
    if (key != _cacheKey) {
      final (paths, box, fills) = buildOutlines();
      _outlines = paths;
      _layoutBox = box;
      _outlineFills = fills;
      _cacheKey = key;
    }
    return _outlines;
  }

  /// The letters grouped by fill (one group unless letters have their own
  /// colors).
  List<(InkPaint?, List<InkPath>)> get paintGroups {
    final paths = outlines;
    final fills = _outlineFills;
    if (fills == null) return [(fill, paths)];
    final groups = <(InkPaint?, List<InkPath>)>[];
    for (final (i, p) in paths.indexed) {
      final f = fills[i] ?? fill;
      final at = groups.indexWhere((g) => g.$1 == f);
      if (at < 0) {
        groups.add((f, [p]));
      } else {
        groups[at].$2.add(p);
      }
    }
    return groups;
  }

  /// Draws letter groups in their own fills (when there are several).
  @override
  void renderElement(Canvas canvas) {
    outlines; // lays out (and finds the fills)
    if (_outlineFills == null || isMasking || isEmpty) return super.renderElement(canvas);
    for (final (f, paths) in paintGroups) {
      final paint = paintFor(f, opacity);
      if (paint == null) continue;
      final p = Path();
      for (final o in paths) {
        o.addTo(p);
      }
      canvas.drawPath(p, paint);
    }
    final sp = strokePaint(opacity);
    if (sp != null) {
      final s = stroke!;
      final path = toFlutterPath();
      canvas.drawPath(s.dashPattern.isEmpty ? path : dashPath(path, s.dashPattern), sp);
    }
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
  String svgFontAttrs() => _fontAttrs(fontFamily, fontStyle, fontSize);
}

/// SVG font attributes for a family, style and size. [explicit] spells out
/// normal weight and style too (for letters inside differently styled text).
String _fontAttrs(String family, String style, double size, {bool explicit = false}) {
  final info = FontLibrary.instance.find(family, style);
  final weight = info?.weight ?? (style.toLowerCase().contains('bold') ? 700 : 400);
  final italic = info?.italic ?? style.toLowerCase().contains('italic');
  return 'font-family="${_xml(family)}" font-size="${fmt(size)}"'
      '${weight != 400 ? ' font-weight="$weight"' : explicit ? ' font-weight="normal"' : ''}'
      '${italic ? ' font-style="italic"' : explicit ? ' font-style="normal"' : ''}';
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
///
/// Beyond Inkpad, letters can have their own font, style, size and fill:
/// the text is a list of [runs], each overriding the text's own settings.
class InkText extends InkStylable with InkTypography {
  /// The text in stretches of one style each.
  List<TextRun> runs;
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
    String text = '',
    List<TextRun>? runs,
    required this.fontFamily,
    this.fontStyle = 'Regular',
    this.fontSize = FontLibrary.defaultSize,
    this.alignment = TextAlignment.left,
    this.width,
    this.placement = Affine.identity,
    super.fill,
    super.stroke,
    super.opacity,
  }) : runs = runs ?? [TextRun(text)];

  static const minimumWidth = 20.0; // Inkpad's kMinWidth

  @override
  String get text => runs.plainText;

  /// Replacing the text keeps the styles of the letters that stay; new
  /// letters take the style of the letter before them.
  set text(String value) => runs = runs.edited(value);

  /// Whether any letters are styled differently from the rest.
  bool get isStyled => runs.isStyled;

  String familyOf(TextRunStyle s) => s.fontFamily ?? fontFamily;
  String styleOf(TextRunStyle s) => s.fontStyle ?? fontStyle;
  double sizeOf(TextRunStyle s) => s.fontSize ?? fontSize;

  LoadedFace _faceOf(TextRunStyle s) {
    if (s.fontFamily == null && s.fontStyle == null) return face;
    final lib = FontLibrary.instance;
    return lib.face(familyOf(s), styleOf(s)) ?? lib.fallback;
  }

  @override
  Object get _layoutKey => (
        Object.hashAll(runs),
        // Fonts of styled letters, which may finish loading later.
        Object.hashAll([for (final r in runs) identityHashCode(_faceOf(r.style))]),
        fontFamily,
        fontStyle,
        fontSize,
        alignment,
        width,
        placement,
      );

  List<LaidLine> _layout() => layoutRuns(
        [for (final r in runs) LayoutRun(r.text, _faceOf(r.style).font, sizeOf(r.style).clamp(0.1, 10000))],
        maxWidth: width,
      );

  /// The first baseline: at the top line's ascent for area text, at the
  /// anchor for point text.
  double _firstBaseline(List<LaidLine> lines) => width == null ? 0.0 : lines.first.ascent;

  /// Lines of text with their baseline and left edge in text space, and
  /// their text in stretches of one run each.
  List<({String text, double x, double baseline, double width, List<({int run, String text})> segments})> get lines {
    final laid = _layout();
    final first = _firstBaseline(laid);
    return [
      for (final l in laid)
        (
          text: l.glyphs.map((g) => g.glyph.sourceText).join(),
          x: _lineX(l),
          baseline: first + l.baseline,
          width: l.width,
          segments: l.segments,
        ),
    ];
  }

  /// A line's left edge: across the box for area text, or around the
  /// anchor point for point text.
  double _lineX(LaidLine l) {
    final w = width;
    if (w != null) {
      return switch (alignment) {
        TextAlignment.left => 0,
        TextAlignment.center => (w - l.width) / 2,
        TextAlignment.right => w - l.width,
      };
    }
    return switch (alignment) {
      TextAlignment.left => 0,
      TextAlignment.center => -l.width / 2,
      TextAlignment.right => -l.width,
    };
  }

  @override
  (List<InkPath>, Rect, List<InkPaint?>?) buildOutlines() {
    if (text.isEmpty) return (const <InkPath>[], _emptyBox(), null);
    final laid = _layout();
    final firstBaseline = _firstBaseline(laid);
    final styledFills = runs.any((r) => r.style.fill != null);
    final paths = <InkPath>[];
    final fills = <InkPaint?>[];
    var minX = double.infinity, maxX = -double.infinity;
    for (final line in laid) {
      final baseline = firstBaseline + line.baseline;
      final x0 = _lineX(line);
      minX = math.min(minX, x0);
      maxX = math.max(maxX, x0 + line.width);
      for (final g in line.glyphs) {
        final gx = x0 + g.x;
        final glyphPaths = _contoursToPaths(g.glyph.commands, (x, y) => placement.apply(Offset(gx + x, baseline - y)));
        paths.addAll(glyphPaths);
        if (styledFills) fills.addAll(List.filled(glyphPaths.length, runs[g.run].style.fill));
      }
    }
    final top = firstBaseline - laid.first.ascent;
    final bottom = firstBaseline + laid.last.baseline + laid.last.descent;
    final box = width != null
        ? Rect.fromLTRB(0, 0, width!, bottom)
        : Rect.fromLTRB(minX.isFinite ? minX : 0, top, maxX.isFinite ? maxX : 0, bottom);
    return (paths, box, styledFills ? fills : null);
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

  /// SVG paint attributes for a fill.
  static String _fillAttrs(SvgWriter w, InkPaint? f, Rect bounds) => switch (f) {
        InkGradient g => ' fill="url(#${w.gradient(g, bounds)})"',
        InkColor c => ' fill="${c.hexValue}"${c.alpha != 1 ? ' fill-opacity="${fmt(c.alpha)}"' : ''}',
        _ => ' fill="none"',
      };

  @override
  String elementSvg(SvgWriter w) {
    if (isMasking || w.make) return super.elementSvg(w); // masks export as outlines + clip
    final t = placement;
    final attrs = StringBuffer(' transform="matrix(${[t.a, t.b, t.c, t.d, t.tx, t.ty].map(fmt).join(' ')})"');
    attrs.write(' ${svgFontAttrs()}');
    attrs.write(_fillAttrs(w, fill, bounds));
    final s = stroke;
    if (s != null && s.willRender) {
      for (final e in w.strokeAttributes(s, bounds).entries) {
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
    if (isStyled) {
      // The letters' styles, exactly, for reading the file back.
      attrs.write(" inkpad:runs='${_xml(jsonEncode([for (final r in runs) r.toJson()])).replaceAll("'", '&apos;')}'");
    }
    attrs.write(' xml:space="preserve"');
    String segment(({int run, String text}) seg) {
      final st = runs[seg.run].style;
      if (st.isPlain) return _xml(seg.text);
      final a = StringBuffer();
      if (st.fontFamily != null || st.fontStyle != null || st.fontSize != null) {
        a.write(' ${_fontAttrs(familyOf(st), styleOf(st), sizeOf(st), explicit: true)}');
      }
      if (st.fill != null) a.write(_fillAttrs(w, st.fill, bounds));
      return '<tspan$a>${_xml(seg.text)}</tspan>';
    }

    final spans = [
      for (final l in lines)
        '<tspan x="${fmt(width != null ? l.x : 0)}" y="${fmt(l.baseline)}">${l.segments.map(segment).join()}</tspan>',
    ];
    return '<text$attrs${opacityAttr()}>${spans.join()}</text>';
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'text': text,
        if (isStyled) 'runs': [for (final r in runs) r.toJson()],
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
        runs: j['runs'] == null ? null : [for (final r in j['runs'] as List) TextRun.fromJson(r)],
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
  (List<InkPath>, Rect, List<InkPaint?>?) buildOutlines() {
    if (text.isEmpty) return (const <InkPath>[], guide.bounds, null);
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
    return (paths, guide.bounds, null);
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
  String elementSvg(SvgWriter w) {
    if (isMasking || w.make) return super.elementSvg(w);
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
      for (final e in w.strokeAttributes(s, bounds).entries) {
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
