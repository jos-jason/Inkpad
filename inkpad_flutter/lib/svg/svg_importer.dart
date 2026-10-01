import 'dart:math' as math;
import 'dart:ui';

import 'package:xml/xml.dart';

import '../model/bezier_node.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import 'svg_path_parser.dart';
import 'svg_values.dart';

/// The outcome of importing an SVG file.
class SvgImportResult {
  final InkDrawing drawing;

  /// Human-readable notes about content that couldn't be imported exactly.
  final List<String> warnings;

  const SvgImportResult(this.drawing, this.warnings);
}

class SvgImportException implements Exception {
  final String message;
  const SvgImportException(this.message);

  @override
  String toString() => message;
}

/// Converts SVG markup into a drawing. Ported in spirit from WDSVGParser.
///
/// Supported: paths, rect (incl. rounded), circle, ellipse, line, polyline,
/// polygon, groups, nested svg, `use`/`symbol`, transforms, presentation
/// attributes, `style` attributes, simple CSS `<style>` rules (tag, .class,
/// #id), inheritance, opacity, dashes, fill rules (shapes with holes).
/// Top-level groups become layers, as in Inkpad.
///
/// Approximated: gradients (become their average color), clipping and
/// masks (ignored). Skipped: text, images.
SvgImportResult importSvg(String source) => _SvgImporter(source).run();

/// Properties that children inherit from their parents.
const _inherited = {
  'fill', 'fill-opacity', 'fill-rule', 'stroke', 'stroke-width', 'stroke-opacity',
  'stroke-linecap', 'stroke-linejoin', 'stroke-dasharray', 'color', 'visibility',
};

/// Properties that can be set by attribute, CSS or style="".
const _styleProperties = {..._inherited, 'opacity', 'display'};

/// Elements that never render directly.
const _nonRendering = {
  'defs', 'title', 'desc', 'metadata', 'style', 'script', 'linearGradient', 'radialGradient',
  'pattern', 'clipPath', 'mask', 'marker', 'symbol', 'filter', 'namedview', 'font', 'font-face',
};

/// One compound selector, e.g. `path.outline#main`.
class _Compound {
  final String? tag;
  final String? id;
  final List<String> classes;

  _Compound(this.tag, this.id, this.classes);

  static final _syntax = RegExp(r'^(\*|[a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)$');

  static _Compound? parse(String text) {
    final m = _syntax.firstMatch(text);
    if (m == null || text.isEmpty) return null;
    String? id;
    final classes = <String>[];
    for (final part in RegExp(r'[.#][\w-]+').allMatches(m.group(2)!)) {
      final p = part.group(0)!;
      p.startsWith('#') ? id = p.substring(1) : classes.add(p.substring(1));
    }
    return _Compound(m.group(1) == '*' ? null : m.group(1), id, classes);
  }

  int get specificity => (id != null ? 100 : 0) + classes.length * 10 + (tag != null ? 1 : 0);

  bool matches(XmlElement e) {
    if (tag != null && e.name.local != tag) return false;
    if (id != null && e.getAttribute('id') != id) return false;
    if (classes.isEmpty) return true;
    final have = (e.getAttribute('class') ?? '').split(RegExp(r'\s+')).toSet();
    return classes.every(have.contains);
  }
}

/// A CSS rule with a selector made of compounds joined by descendant
/// (space) or child (`>`) combinators.
class _CssRule {
  final List<_Compound> parts;

  /// combinators[i] joins parts[i] and parts[i + 1]: true for `>`.
  final List<bool> childOf;
  final int order;
  final Map<String, String> declarations;
  final int specificity;

  _CssRule(this.parts, this.childOf, this.order, this.declarations)
      : specificity = parts.fold(0, (a, p) => a + p.specificity);

  static _CssRule? parse(String selector, int order, Map<String, String> declarations) {
    final tokens = selector.trim().replaceAll('>', ' > ').split(RegExp(r'\s+'));
    final parts = <_Compound>[];
    final childOf = <bool>[];
    var pendingChild = false;
    for (final t in tokens) {
      if (t == '>') {
        if (parts.isEmpty || pendingChild) return null;
        pendingChild = true;
        continue;
      }
      final c = _Compound.parse(t);
      if (c == null) return null;
      if (parts.isNotEmpty) childOf.add(pendingChild);
      pendingChild = false;
      parts.add(c);
    }
    if (parts.isEmpty || pendingChild) return null;
    return _CssRule(parts, childOf, order, declarations);
  }

  bool matches(XmlElement e) => parts.last.matches(e) && _matchAncestors(e, parts.length - 2);

  /// Matches parts[0..index] against the ancestors of [e], right to left.
  bool _matchAncestors(XmlElement e, int index) {
    if (index < 0) return true;
    var ancestor = e.parentElement;
    while (ancestor != null) {
      if (parts[index].matches(ancestor) && _matchAncestors(ancestor, index - 1)) return true;
      if (childOf[index]) return false; // `>` only allows the direct parent
      ancestor = ancestor.parentElement;
    }
    return false;
  }
}

class _Context {
  final Affine ctm;
  final Map<String, String> inherited;
  final int useDepth;

  const _Context(this.ctm, this.inherited, [this.useDepth = 0]);
}

class _SvgImporter {
  final String source;
  final Map<String, XmlElement> _ids = {};
  final List<_CssRule> _css = [];
  final Map<String, int> _skipped = {};
  final Set<String> _notes = {};

  double _viewWidth = 0, _viewHeight = 0;

  _SvgImporter(this.source);

  SvgImportResult run() {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(source);
    } on XmlException catch (e) {
      throw SvgImportException('This file isn\'t valid SVG (${e.message}).');
    }
    final root = doc.rootElement;
    if (root.name.local != 'svg') {
      throw const SvgImportException('This file isn\'t an SVG image.');
    }

    for (final e in doc.descendantElements) {
      final id = e.getAttribute('id');
      if (id != null) _ids.putIfAbsent(id, () => e);
      if (e.name.local == 'style') _parseCss(e.innerText);
    }

    // Document size: the viewBox if present (so coordinates are kept as-is),
    // else width/height, else the content's extent.
    final viewBox = parseNumberList(root.getAttribute('viewBox'));
    double? width, height;
    var ctm = Affine.identity;
    if (viewBox.length == 4 && viewBox[2] > 0 && viewBox[3] > 0) {
      width = viewBox[2];
      height = viewBox[3];
      ctm = Affine.translation(-viewBox[0], -viewBox[1]);
    } else {
      width = parseLength(root.getAttribute('width'));
      height = parseLength(root.getAttribute('height'));
    }
    _viewWidth = width ?? 768;
    _viewHeight = height ?? 1024;

    final rootStyle = _computeStyle(root, const {});
    final context = _Context(ctm, rootStyle.$1);
    final layers = _buildLayers(root, context);

    final drawing = InkDrawing(layers: layers, activeLayerIndex: layers.length - 1);
    if (width == null || height == null) {
      Rect? content;
      for (final e in drawing.allElements) {
        content = unionRects(content, e.styleBounds);
      }
      drawing.width = width ?? math.max(1, content?.right ?? 768).ceilToDouble();
      drawing.height = height ?? math.max(1, content?.bottom ?? 1024).ceilToDouble();
    } else {
      drawing.width = width;
      drawing.height = height;
    }

    return SvgImportResult(drawing, _warnings());
  }

  List<String> _warnings() => [
        for (final MapEntry(key: what, value: n) in _skipped.entries) 'Skipped $n $what${n == 1 ? '' : 's'}',
        ..._notes,
      ];

  void _skip(String what) => _skipped[what] = (_skipped[what] ?? 0) + 1;

  // ---- Layers -------------------------------------------------------------

  /// Inkpad's rule: a top-level group with an id becomes a layer; loose
  /// top-level elements are collected into layers of their own.
  /// Inkscape's layers (inkscape:groupmode="layer") are recognised too.
  List<InkLayer> _buildLayers(XmlElement root, _Context context) {
    final layers = <InkLayer>[];
    var loose = <InkElement>[];

    String nextName() {
      var i = layers.length + 1;
      while (layers.any((l) => l.name == 'Layer $i')) {
        i++;
      }
      return 'Layer $i';
    }

    void flushLoose() {
      if (loose.isEmpty) return;
      layers.add(InkLayer(name: nextName(), elements: loose));
      loose = [];
    }

    for (final child in root.childElements) {
      if (_isLayerGroup(child)) {
        flushLoose();
        final (inherited, own) = _computeStyle(child, context.inherited);
        final ctm = parseTransform(child.getAttribute('transform')).then(context.ctm);
        final elements = <InkElement>[];
        // A hidden layer keeps its contents; the layer itself is hidden.
        final visible = own['display'] != 'none' && inherited['visibility'] != 'hidden';
        _addChildren(child, _Context(ctm, {...inherited}..remove('visibility')), elements);
        layers.add(InkLayer(
          name: _attrLocal(child, 'label') ?? _attrLocal(child, 'layerName') ?? child.getAttribute('id')!,
          opacity: _opacity(own),
          visible: visible,
          elements: elements,
        ));
      } else {
        final e = _element(child, context);
        if (e != null) loose.add(e);
      }
    }
    flushLoose();
    return layers.isEmpty ? [InkLayer(name: 'Layer 1')] : layers;
  }

  bool _isLayerGroup(XmlElement e) =>
      e.name.local == 'g' &&
      (_attrLocal(e, 'groupmode') == 'layer' || _attrLocal(e, 'layerName') != null || e.getAttribute('id') != null);

  /// A (possibly namespaced) attribute by its local name, e.g. `xlink:href`.
  String? _attrLocal(XmlElement e, String local) {
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }

  // ---- Styles -------------------------------------------------------------

  void _parseCss(String css) {
    css = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
    var i = 0;
    while (i < css.length) {
      final open = css.indexOf('{', i);
      if (open < 0) break;
      final prelude = css.substring(i, open).trim();
      // Find the matching close brace (at-rules like @media nest blocks).
      var depth = 1, j = open + 1;
      while (j < css.length && depth > 0) {
        if (css[j] == '{') depth++;
        if (css[j] == '}') depth--;
        j++;
      }
      final body = css.substring(open + 1, math.max(open + 1, j - 1));
      i = j;
      if (prelude.startsWith('@')) {
        if (!prelude.startsWith('@font-face')) _notes.add('Some CSS rules (${prelude.split(' ').first}) were ignored');
        continue;
      }
      final declarations = parseDeclarations(body);
      for (final selector in prelude.split(',')) {
        final rule = _CssRule.parse(selector, _css.length, declarations);
        if (rule == null) {
          _notes.add('Some CSS selectors weren\'t understood, so a few styles may be missing');
        } else {
          _css.add(rule);
        }
      }
    }
  }

  /// Returns (inherited properties for this element and its children,
  /// all properties specified on this element).
  (Map<String, String>, Map<String, String>) _computeStyle(XmlElement e, Map<String, String> parent) {
    final specified = <String, String>{};
    for (final a in e.attributes) {
      if (_styleProperties.contains(a.name.local)) specified[a.name.local] = a.value.trim();
    }
    if (_css.isNotEmpty) {
      final matching = _css.where((r) => r.matches(e)).toList()
        ..sort((a, b) => a.specificity != b.specificity ? a.specificity - b.specificity : a.order - b.order);
      for (final r in matching) {
        specified.addAll(r.declarations);
      }
    }
    specified.addAll(parseDeclarations(e.getAttribute('style')));

    final inherited = Map.of(parent);
    for (final MapEntry(:key, :value) in specified.entries) {
      if (_inherited.contains(key) && value != 'inherit') inherited[key] = value;
    }
    return (inherited, specified);
  }

  double _opacity(Map<String, String> own) =>
      (double.tryParse(own['opacity'] ?? '') ?? 1).clamp(0.0, 1.0);

  double get _viewDiagonal => math.sqrt((_viewWidth * _viewWidth + _viewHeight * _viewHeight) / 2);

  double _length(XmlElement e, String name, {required double percentOf, double fallback = 0}) =>
      parseLength(e.getAttribute(name), percentOf: percentOf) ?? fallback;

  // ---- Elements -----------------------------------------------------------

  void _addChildren(XmlElement parent, _Context context, List<InkElement> out) {
    for (final child in parent.childElements) {
      final e = _element(child, context);
      if (e != null) out.add(e);
    }
  }

  InkElement? _element(XmlElement e, _Context parent) {
    final name = e.name.local;
    if (_nonRendering.contains(name)) return null;

    final (inherited, own) = _computeStyle(e, parent.inherited);
    if (own['display'] == 'none' || inherited['visibility'] == 'hidden') return null;

    final ctm = parseTransform(e.getAttribute('transform')).then(parent.ctm);
    final context = _Context(ctm, inherited, parent.useDepth);

    if (e.getAttribute('clip-path') != null || own['clip-path'] != null) {
      _notes.add('Clipping paths were ignored, so some shapes may show more than in the original');
    }
    if (e.getAttribute('mask') != null) _notes.add('Masks were ignored');

    InkElement? result;
    switch (name) {
      case 'g' || 'a' || 'switch':
        result = _group(e, context);
      case 'svg':
        final x = _length(e, 'x', percentOf: _viewWidth), y = _length(e, 'y', percentOf: _viewHeight);
        result = _group(e, _Context(Affine.translation(x, y).then(ctm), inherited, parent.useDepth));
      case 'use':
        result = _use(e, context);
      case 'path':
        result = _shape(parseSvgPathData(e.getAttribute('d') ?? ''), context);
      case 'rect':
        result = _shape(_rect(e), context);
      case 'circle':
        final r = _length(e, 'r', percentOf: _viewDiagonal);
        final c = Offset(_length(e, 'cx', percentOf: _viewWidth), _length(e, 'cy', percentOf: _viewHeight));
        result = r > 0 ? _shape([InkPath.oval(Rect.fromCircle(center: c, radius: r))], context) : null;
      case 'ellipse':
        final rx = _length(e, 'rx', percentOf: _viewWidth), ry = _length(e, 'ry', percentOf: _viewHeight);
        final c = Offset(_length(e, 'cx', percentOf: _viewWidth), _length(e, 'cy', percentOf: _viewHeight));
        result = rx > 0 && ry > 0
            ? _shape([InkPath.oval(Rect.fromCenter(center: c, width: rx * 2, height: ry * 2))], context)
            : null;
      case 'line':
        final p1 = Offset(_length(e, 'x1', percentOf: _viewWidth), _length(e, 'y1', percentOf: _viewHeight));
        final p2 = Offset(_length(e, 'x2', percentOf: _viewWidth), _length(e, 'y2', percentOf: _viewHeight));
        result = _shape([InkPath(nodes: [BezierNode.anchor(p1), BezierNode.anchor(p2)])], context, canFill: false);
      case 'polyline' || 'polygon':
        final n = parseNumberList(e.getAttribute('points'));
        final nodes = [for (var i = 0; i + 1 < n.length; i += 2) BezierNode.anchor(Offset(n[i], n[i + 1]))];
        result = nodes.length > 1 ? _shape([InkPath(nodes: nodes, closed: name == 'polygon')], context) : null;
      case 'text':
        _skip('text element');
      case 'image':
        _skip('image');
      case 'foreignObject':
        _skip('embedded HTML element');
    }

    if (result != null) result.opacity *= _opacity(own);
    return result;
  }

  InkElement? _group(XmlElement e, _Context context) {
    final children = <InkElement>[];
    _addChildren(e, context, children);
    if (children.isEmpty) return null;
    // Like Inkpad, a group of one is unwrapped.
    if (children.length == 1) return children.single;
    return InkGroup(children);
  }

  InkElement? _use(XmlElement e, _Context context) {
    final href = _attrLocal(e, 'href');
    if (href == null || !href.startsWith('#')) return null;
    final target = _ids[href.substring(1)];
    if (target == null) {
      _notes.add('Some reused shapes (<use>) referred to missing elements');
      return null;
    }
    if (context.useDepth > 16 || target == e) return null; // circular references
    final x = _length(e, 'x', percentOf: _viewWidth), y = _length(e, 'y', percentOf: _viewHeight);
    final inner = _Context(Affine.translation(x, y).then(context.ctm), context.inherited, context.useDepth + 1);
    // A referenced <symbol> renders like a group.
    if (target.name.local == 'symbol') return _group(target, inner);
    return _element(target, inner);
  }

  List<InkPath> _rect(XmlElement e) {
    final x = _length(e, 'x', percentOf: _viewWidth), y = _length(e, 'y', percentOf: _viewHeight);
    final w = _length(e, 'width', percentOf: _viewWidth), h = _length(e, 'height', percentOf: _viewHeight);
    if (w <= 0 || h <= 0) return [];
    var rx = parseLength(e.getAttribute('rx'), percentOf: _viewWidth);
    var ry = parseLength(e.getAttribute('ry'), percentOf: _viewHeight);
    rx ??= ry;
    ry ??= rx;
    final r = Rect.fromLTWH(x, y, w, h);
    if (rx == null || ry == null || rx <= 0 || ry <= 0) return [InkPath.rect(r)];
    return [_roundedRect(r, math.min(rx, w / 2), math.min(ry, h / 2))];
  }

  InkPath _roundedRect(Rect r, double rx, double ry) {
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

  /// Builds a styled path (or compound path) from local-space geometry.
  InkElement? _shape(List<InkPath> subpaths, _Context context, {bool canFill = true}) {
    subpaths = subpaths.where((p) => p.nodes.length > 1).toList();
    if (subpaths.isEmpty) return null;
    for (final p in subpaths) {
      p.transform(context.ctm);
    }
    final style = context.inherited;
    final scale = context.ctm.scaleFactor;

    final fill = canFill
        ? _resolvePaint(style['fill'] ?? 'black', style['fill-opacity'], style['color'])
        : null;

    StrokeStyle? stroke;
    final strokeColor = _resolvePaint(style['stroke'] ?? 'none', style['stroke-opacity'], style['color']);
    if (strokeColor != null) {
      final width = (parseLength(style['stroke-width'], percentOf: _viewDiagonal) ?? 1) * scale;
      var dashes = style['stroke-dasharray'] == 'none' ? <double>[] : parseNumberList(style['stroke-dasharray']);
      if (dashes.length.isOdd) dashes = [...dashes, ...dashes];
      if (dashes.every((d) => d == 0) || dashes.any((d) => d < 0)) dashes = [];
      stroke = StrokeStyle(
        width: width,
        color: strokeColor,
        cap: switch (style['stroke-linecap']) { 'round' => LineCap.round, 'square' => LineCap.square, _ => LineCap.butt },
        join: switch (style['stroke-linejoin']) { 'round' => LineJoin.round, 'bevel' => LineJoin.bevel, _ => LineJoin.miter },
        dashPattern: dashes.map((d) => d * scale).toList(),
      );
    }

    final rule = style['fill-rule'] == 'evenodd' ? FillRule.evenOdd : FillRule.nonZero;
    if (subpaths.length == 1) {
      return subpaths.single
        ..fill = fill
        ..stroke = stroke
        ..fillRule = rule;
    }
    return InkCompoundPath(subpaths, fill: fill, stroke: stroke, fillRule: rule);
  }

  InkColor? _resolvePaint(String value, String? opacity, String? currentColor) {
    final paint = parsePaint(value);
    final alpha = (double.tryParse(opacity ?? '') ?? 1).clamp(0.0, 1.0);
    InkColor? color;
    switch (paint) {
      case null || SvgNoPaint():
        return null;
      case SvgColorPaint(color: final c):
        color = c;
      case SvgCurrentColorPaint():
        color = parseColor(currentColor) ?? InkColor.black;
      case SvgUrlPaint(:final id, :final fallback):
        final target = _ids[id];
        final kind = target?.name.local;
        if (kind == 'linearGradient' || kind == 'radialGradient') {
          _notes.add('Gradients were replaced by their average color (gradients aren\'t supported yet)');
          color = _averageGradientColor(target!);
        } else {
          // Patterns usually hold images we can't show; leaving them out
          // looks closer to the original than a solid block.
          if (kind == 'pattern') _notes.add('Pattern fills were left out (patterns aren\'t supported yet)');
          if (fallback is! SvgColorPaint) return null;
          color = fallback.color;
        }
    }
    if (color == null) return null;
    return color.withAlpha(color.alpha * alpha);
  }

  InkColor? _averageGradientColor(XmlElement gradient, [int depth = 0]) {
    var stops = gradient.childElements.where((c) => c.name.local == 'stop').toList();
    // Stops may be inherited from another gradient via href.
    final href = _attrLocal(gradient, 'href');
    if (stops.isEmpty && href != null && href.startsWith('#') && depth < 8) {
      final parent = _ids[href.substring(1)];
      if (parent != null) return _averageGradientColor(parent, depth + 1);
    }
    if (stops.isEmpty) return null;
    var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    for (final stop in stops) {
      final (_, own) = _computeStyle(stop, const {});
      final decl = {...own, ...parseDeclarations(stop.getAttribute('style'))};
      final c = parseColor(stop.getAttribute('stop-color') ?? decl['stop-color'] ?? 'black') ?? InkColor.black;
      final o = double.tryParse(stop.getAttribute('stop-opacity') ?? decl['stop-opacity'] ?? '') ?? 1;
      r += c.red;
      g += c.green;
      b += c.blue;
      a += c.alpha * o;
    }
    final n = stops.length;
    return InkColor(r / n, g / n, b / n, a / n);
  }
}
