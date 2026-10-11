import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:xml/xml.dart';

import '../model/bezier_node.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import '../text/font_library.dart';
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
/// Gradient fills (linear and radial) and clip paths are imported as such;
/// masks made of solid white shapes become clipping masks.
/// Approximated: gradient outlines (become a solid color), soft masks
/// (even transparency), patterns (left out). Embedded bitmap images are
/// imported; linked images are skipped. Text keeps one font per text
/// object (styled runs take the text's own style).
SvgImportResult importSvg(String source) => _SvgImporter(source).run();

/// Properties that children inherit from their parents.
const _inherited = {
  'fill', 'fill-opacity', 'fill-rule', 'clip-rule', 'stroke', 'stroke-width', 'stroke-opacity',
  'stroke-linecap', 'stroke-linejoin', 'stroke-dasharray', 'color', 'visibility',
  'font-family', 'font-size', 'font-weight', 'font-style', 'text-anchor',
};

/// Properties that can be set by attribute, CSS or style="".
const _styleProperties = {..._inherited, 'opacity', 'display', 'clip-path', 'mask', 'stop-color', 'stop-opacity'};

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
        result = _text(e, context);
      case 'image':
        result = _image(e, context);
      case 'foreignObject':
        _skip('embedded HTML element');
    }

    final clipId = _funcIri(own['clip-path']);
    if (result != null && clipId != null) result = _applyClip(result, clipId, ctm);
    final maskId = _funcIri(own['mask']);
    if (result != null && maskId != null) result = _applyMask(result, maskId, ctm);

    if (result != null) result.opacity *= _opacity(own);
    return result;
  }

  static final _funcIriRe = RegExp(r'''^url\(\s*["']?#([^)"']+)["']?\s*\)''');

  String? _funcIri(String? value) => value == null ? null : _funcIriRe.firstMatch(value.trim())?.group(1);

  // ---- Clipping and masks ------------------------------------------------

  /// The bounds of [e] in the user space of [ctm] (before [ctm] is applied).
  Rect _userBounds(InkElement e, Affine ctm) {
    final b = e.bounds, inv = ctm.inverted();
    final pts = [b.topLeft, b.topRight, b.bottomLeft, b.bottomRight].map(inv.apply).toList();
    return pts.skip(1).fold(Rect.fromPoints(pts[0], pts[0]), (r, p) => r.expandToInclude(Rect.fromPoints(p, p)));
  }

  /// Maps the unit square onto [r] (for objectBoundingBox units).
  Affine _boxTransform(Rect r) => Affine(r.width, 0, 0, r.height, r.left, r.top);

  /// Wraps [result] in a clipping mask made from the `<clipPath>` [id].
  /// Ported in spirit from -[WDSVGParser clip:].
  InkElement? _applyClip(InkElement result, String id, Affine ctm) {
    final clip = _ids[id];
    if (clip == null || clip.name.local != 'clipPath') {
      _notes.add('Some clipping paths were missing and were ignored');
      return result;
    }
    var base = parseTransform(clip.getAttribute('transform'));
    if (clip.getAttribute('clipPathUnits') == 'objectBoundingBox') {
      base = base.then(_boxTransform(_userBounds(result, ctm)));
    }
    base = base.then(ctm);

    final (clipStyle, _) = _computeStyle(clip, const {});
    final shapes = <InkElement>[];
    _addChildren(clip, _Context(base, clipStyle), shapes);
    // An empty clip path hides the element completely.
    final mask = _maskShape(shapes, evenOdd: _clipRuleIsEvenOdd(clip));
    return mask == null ? null : _wrap(mask, result);
  }

  bool _clipRuleIsEvenOdd(XmlElement clip) {
    final shapes = clip.childElements.where((c) => !_nonRendering.contains(c.name.local)).toList();
    if (shapes.length != 1) return false;
    final (style, _) = _computeStyle(shapes.single, _computeStyle(clip, const {}).$1);
    return style['clip-rule'] == 'evenodd';
  }

  /// A `<mask>` made only of solid white shapes is just a clip. Softer masks
  /// (gradients, transparency) are approximated: clipped to the mask's shapes
  /// with their average brightness as an even transparency, which keeps
  /// effects like gloss highlights translucent.
  InkElement? _applyMask(InkElement result, String id, Affine ctm) {
    final mask = _ids[id];
    if (mask == null || mask.name.local != 'mask') return result;
    var base = Affine.identity;
    if (mask.getAttribute('maskContentUnits') == 'objectBoundingBox') {
      base = _boxTransform(_userBounds(result, ctm));
    }
    base = base.then(ctm);
    final (maskStyle, _) = _computeStyle(mask, const {});
    final shapes = <InkElement>[];
    _addChildren(mask, _Context(base, maskStyle), shapes);
    final shape = _maskShape(shapes);
    if (shape == null) return null;
    final wrapped = _wrap(shape, result);
    if (!shapes.every(_isSolidWhite)) {
      _notes.add('Soft masks (fades) were approximated with even transparency');
      wrapped.opacity *= _maskStrength(shapes);
    }
    return wrapped;
  }

  /// Average luminance × alpha of a mask's contents (1 = fully shows).
  double _maskStrength(List<InkElement> shapes) {
    final values = <double>[];
    void collect(InkElement e, double opacity) {
      if (e is InkGroup) {
        for (final c in e.elements) {
          collect(c, opacity * e.opacity);
        }
      } else if (e is InkStylable) {
        final f = e.fill;
        final colors = switch (f) {
          InkGradient() => [for (final s in f.stops) s.color],
          InkColor() => [f],
          _ => <InkColor>[],
        };
        for (final c in colors) {
          values.add((0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue) * c.alpha * opacity * e.opacity);
        }
      }
    }

    for (final e in shapes) {
      collect(e, 1);
    }
    return values.isEmpty ? 0 : (values.reduce((a, b) => a + b) / values.length).clamp(0.0, 1.0);
  }

  bool _isSolidWhite(InkElement e) {
    if (e is InkGroup) return e.opacity >= 0.99 && e.elements.every(_isSolidWhite);
    if (e is! InkStylable || e.isMasking || e.opacity < 0.99) return false;
    final f = e.fill;
    final strokeOk = e.stroke == null || !e.stroke!.willRender;
    return strokeOk && f is InkColor && f.alpha >= 0.99 && f.red > 0.99 && f.green > 0.99 && f.blue > 0.99;
  }

  /// One unstyled outline made from all of [shapes]' geometry.
  InkStylable? _maskShape(List<InkElement> shapes, {bool evenOdd = false}) {
    final subpaths = <InkPath>[];
    void collect(InkElement e) {
      switch (e) {
        case InkGroup():
          e.elements.forEach(collect);
        case InkCompoundPath():
          subpaths.addAll(e.subpaths);
        case InkPath():
          subpaths.add(InkPath(nodes: e.nodes, closed: e.closed));
      }
    }

    shapes.forEach(collect);
    if (subpaths.isEmpty) return null;
    final rule = evenOdd ? FillRule.evenOdd : FillRule.nonZero;
    if (subpaths.length == 1) return subpaths.single..fillRule = rule;
    return InkCompoundPath(subpaths, fillRule: rule);
  }

  /// Makes [mask] clip [content] (a group's children are clipped directly).
  InkStylable _wrap(InkStylable mask, InkElement content) {
    mask.maskedElements = content is InkGroup && content.opacity == 1 ? content.elements : [content];
    return mask;
  }

  static final _dataUri = RegExp(r'^data:([^;,]*)((?:;[^;,]*)*),(.*)$', dotAll: true);

  /// An embedded `<image>`, positioned by x/y/width/height and
  /// preserveAspectRatio. "slice" crops with a clipping mask.
  InkElement? _image(XmlElement e, _Context context) {
    final href = (_attrLocal(e, 'href') ?? '').trim();
    final m = _dataUri.firstMatch(href);
    if (m == null) {
      _notes.add('Linked images (not embedded in the file) were skipped');
      return null;
    }
    if (m.group(1) == 'image/svg+xml') {
      _skip('embedded SVG image');
      return null;
    }
    final Uint8List bytes;
    try {
      final payload = m.group(3)!;
      bytes = m.group(2)!.contains(';base64')
          ? base64Decode(payload.replaceAll(RegExp(r'\s'), ''))
          : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
    } on FormatException {
      _skip('unreadable image');
      return null;
    }
    final data = ImageData.register(bytes);
    if (data == null || data.width == 0 || data.height == 0) {
      _skip('image in an unsupported format');
      return null;
    }

    final iw = data.width.toDouble(), ih = data.height.toDouble();
    final x = _length(e, 'x', percentOf: _viewWidth), y = _length(e, 'y', percentOf: _viewHeight);
    final w = parseLength(e.getAttribute('width'), percentOf: _viewWidth) ?? iw;
    final h = parseLength(e.getAttribute('height'), percentOf: _viewHeight) ?? ih;
    if (w <= 0 || h <= 0) return null;

    final aspect = (e.getAttribute('preserveAspectRatio') ?? 'xMidYMid meet').trim().split(RegExp(r'\s+'));
    final align = aspect.first;
    final Affine local;
    var slice = false;
    if (align == 'none') {
      local = Affine.scale(w / iw, h / ih).then(Affine.translation(x, y));
    } else {
      slice = aspect.contains('slice');
      final s = slice ? math.max(w / iw, h / ih) : math.min(w / iw, h / ih);
      double offset(String axis, double room) => align.contains('${axis}Min')
          ? 0
          : align.contains('${axis}Max')
              ? room
              : room / 2;
      local = Affine.scale(s, s).then(Affine.translation(x + offset('x', w - iw * s), y + offset('Y', h - ih * s)));
    }
    final image = InkImage(data, placement: local.then(context.ctm));
    if (!slice) return image;
    final crop = InkPath.rect(Rect.fromLTWH(x, y, w, h))..transform(context.ctm);
    return crop..maskedElements = [image];
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
    return [InkPath.roundedRect(r, math.min(rx, w / 2), math.min(ry, h / 2))];
  }


  /// Builds a styled path (or compound path) from local-space geometry.
  InkElement? _shape(List<InkPath> subpaths, _Context context, {bool canFill = true}) {
    subpaths = subpaths.where((p) => p.nodes.length > 1).toList();
    if (subpaths.isEmpty) return null;
    // Bounds before transforming, for gradients in objectBoundingBox units.
    final localBounds = subpaths.map((p) => p.bounds).reduce((a, b) => a.expandToInclude(b));
    for (final p in subpaths) {
      p.transform(context.ctm);
    }
    final (fill, stroke) = _paints(context, localBounds, canFill: canFill);
    final rule = context.inherited['fill-rule'] == 'evenodd' ? FillRule.evenOdd : FillRule.nonZero;
    if (subpaths.length == 1) {
      return subpaths.single
        ..fill = fill
        ..stroke = stroke
        ..fillRule = rule;
    }
    return InkCompoundPath(subpaths, fill: fill, stroke: stroke, fillRule: rule);
  }

  /// The fill and stroke for something drawn in [context], whose local
  /// bounds (for gradients) are [localBounds].
  (InkPaint?, StrokeStyle?) _paints(_Context context, Rect localBounds, {bool canFill = true}) {
    final style = context.inherited;
    final scale = context.ctm.scaleFactor;

    final fill = canFill
        ? _resolvePaint(style['fill'] ?? 'black', style['fill-opacity'], style['color'],
            box: localBounds, ctm: context.ctm)
        : null;

    StrokeStyle? stroke;
    final strokePaint = _resolvePaint(style['stroke'] ?? 'none', style['stroke-opacity'], style['color'],
        box: localBounds, ctm: context.ctm);
    if (strokePaint is InkGradient) {
      _notes.add('Gradient outlines were replaced by a solid color (outlines are solid-color only for now)');
    }
    final strokeColor = strokePaint?.representativeColor;
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
    return (fill, stroke);
  }

  // ---- Text -----------------------------------------------------------------

  /// A `<text>` element: point text, Inkpad's wrapping area text (marked
  /// with inkpad:width), or text on a path (`<textPath>`).
  InkElement? _text(XmlElement e, _Context context) {
    final style = context.inherited;
    final family = _fontFamily(style['font-family']);
    final fontStyle = _fontStyle(family, style['font-weight'], style['font-style']);
    final size = parseLength(style['font-size'], percentOf: _viewDiagonal) ?? 16;
    final preserve = _attrLocal(e, 'space') == 'preserve';

    final textPath = e.childElements.where((c) => c.name.local == 'textPath').firstOrNull;
    if (textPath != null) return _textOnPath(e, textPath, context, family, fontStyle, size, preserve);

    // Lines: a tspan with its own y starts a new line.
    final lines = <String>[];
    var current = StringBuffer();
    Offset? anchor;
    double? lastY;
    void visit(XmlNode n) {
      if (n is XmlText || n is XmlCDATA) {
        current.write(n.value);
      } else if (n is XmlElement && n.name.local == 'tspan') {
        final y = parseNumberList(n.getAttribute('y')).firstOrNull;
        final x = parseNumberList(n.getAttribute('x')).firstOrNull;
        if (y != null && lastY != null && y != lastY && current.isNotEmpty) {
          lines.add(current.toString());
          current = StringBuffer();
        }
        if (y != null) lastY = y;
        anchor ??= (x != null || y != null) ? Offset(x ?? 0, y ?? 0) : null;
        n.children.forEach(visit);
      }
    }

    e.children.forEach(visit);
    lines.add(current.toString());
    final text = [for (final l in lines) preserve ? l.replaceAll('\n', ' ') : l.replaceAll(RegExp(r'\s+'), ' ').trim()]
        .join('\n');
    if (text.trim().isEmpty) return null;

    final ownX = parseNumberList(e.getAttribute('x')).firstOrNull;
    final ownY = parseNumberList(e.getAttribute('y')).firstOrNull;
    if (ownX != null || ownY != null) anchor = Offset(ownX ?? 0, ownY ?? 0);

    final width = double.tryParse(_attrLocal(e, 'width') ?? '');
    final InkText t;
    if (width != null && e.getAttribute('inkpad:width') != null) {
      // Inkpad's own area text: the transform places the box's corner.
      final align = TextAlignment.values.asNameMap()[_attrLocal(e, 'align')] ?? TextAlignment.left;
      final typed = _attrLocal(e, 'text') ?? text;
      t = InkText(text: typed, fontFamily: family, fontStyle: fontStyle, fontSize: size, alignment: align, width: width, placement: context.ctm);
    } else {
      final align = switch (style['text-anchor']) { 'middle' => TextAlignment.center, 'end' => TextAlignment.right, _ => TextAlignment.left };
      final at = anchor ?? Offset.zero;
      t = InkText(
        text: text,
        fontFamily: family,
        fontStyle: fontStyle,
        fontSize: size,
        alignment: align,
        placement: Affine.translation(at.dx, at.dy).then(context.ctm),
      );
    }
    final (fill, stroke) = _paints(context, t.layoutBox.shift(anchor ?? Offset.zero));
    return t
      ..fill = fill
      ..stroke = stroke;
  }

  InkElement? _textOnPath(XmlElement text, XmlElement tp, _Context context, String family, String fontStyle, double size, bool preserve) {
    final id = _attrLocal(tp, 'href')?.replaceFirst('#', '');
    final target = id == null ? null : _ids[id];
    if (target == null || target.name.local != 'path') {
      _skip('text on a missing path');
      return null;
    }
    var content = tp.innerText;
    content = preserve ? content.replaceAll('\n', ' ') : content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (content.isEmpty) return null;
    final paths = parseSvgPathData(target.getAttribute('d') ?? '').where((p) => p.nodes.length > 1).toList();
    if (paths.isEmpty) return null;
    final guide = paths.first..transform(parseTransform(target.getAttribute('transform')).then(context.ctm));
    final scale = context.ctm.scaleFactor;
    final result = InkTextPath(text: content, guide: guide, fontFamily: family, fontStyle: fontStyle, fontSize: size * scale);
    final offset = tp.getAttribute('startOffset')?.trim();
    if (offset != null) {
      result.startOffset = offset.endsWith('%')
          ? (double.tryParse(offset.substring(0, offset.length - 1)) ?? 0) / 100 * result.pathLength
          : (double.tryParse(offset) ?? 0) * scale;
    }
    final (fill, stroke) = _paints(context, guide.bounds);
    return result
      ..fill = fill
      ..stroke = stroke;
  }

  /// The first installed family in a CSS font-family list; generic names
  /// and missing fonts keep their name (drawn with the fallback until the
  /// font is available).
  String _fontFamily(String? value) {
    final quotes = RegExp(r'''^["']|["']$''');
    final names = [
      for (final n in (value ?? '').split(','))
        if (n.trim().replaceAll(quotes, '') case final name when name.isNotEmpty) name,
    ];
    final library = FontLibrary.instance;
    for (final n in names) {
      if (library.has(n)) return n;
    }
    const generic = {'serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui'};
    final named = names.where((n) => !generic.contains(n)).firstOrNull;
    if (named == null) return library.defaultFamily;
    _notes.add('Some fonts aren\'t on this device; their text uses ${FontLibrary.fallbackFamily} until they are');
    return named;
  }

  /// The family's style closest to a CSS weight and style.
  String _fontStyle(String family, String? weightValue, String? styleValue) {
    final weight = switch (weightValue) { 'bold' || 'bolder' => 700, 'lighter' => 300, null || 'normal' => 400, _ => int.tryParse(weightValue) ?? 400 };
    final italic = styleValue == 'italic' || styleValue == 'oblique';
    final styles = FontLibrary.instance.stylesOf(family);
    if (styles.isEmpty) {
      return switch ((weight >= 600, italic)) { (true, true) => 'Bold Italic', (true, false) => 'Bold', (false, true) => 'Italic', _ => 'Regular' };
    }
    final candidates = styles.where((f) => f.italic == italic).toList();
    final pool = candidates.isEmpty ? styles : candidates;
    pool.sort((a, b) => (a.weight - weight).abs().compareTo((b.weight - weight).abs()));
    return pool.first.style;
  }

  /// Resolves a fill or stroke value. Gradients need the shape's local
  /// [box] and [ctm]; without them they are approximated by their colors.
  InkPaint? _resolvePaint(String value, String? opacity, String? currentColor, {Rect? box, Affine? ctm}) {
    final paint = parsePaint(value);
    final alpha = (double.tryParse(opacity ?? '') ?? 1).clamp(0.0, 1.0);
    InkColor color;
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
          return _gradient(target!, box ?? Rect.zero, ctm ?? Affine.identity, alpha);
        }
        // Patterns usually hold images we can't show; leaving them out
        // looks closer to the original than a solid block.
        if (kind == 'pattern') _notes.add('Pattern fills were left out (patterns aren\'t supported yet)');
        if (fallback is! SvgColorPaint) return null;
        color = fallback.color;
    }
    return color.withAlpha(color.alpha * alpha);
  }

  /// The gradient and the gradients it inherits from (via href), nearest first.
  List<XmlElement> _gradientChain(XmlElement g) {
    final chain = [g];
    while (chain.length < 8) {
      final href = _attrLocal(chain.last, 'href');
      final next = href != null && href.startsWith('#') ? _ids[href.substring(1)] : null;
      if (next == null || chain.contains(next) || !next.name.local.endsWith('Gradient')) break;
      chain.add(next);
    }
    return chain;
  }

  /// Builds a gradient from a `<linearGradient>`/`<radialGradient>`.
  /// Ported in spirit from WDSVGParser's gradient handling, plus focal
  /// points, spread methods and gradient transforms.
  InkPaint? _gradient(XmlElement g, Rect box, Affine ctm, double alpha) {
    final chain = _gradientChain(g);
    String? attr(String name) {
      for (final e in chain) {
        final v = e.getAttribute(name);
        if (v != null) return v;
      }
      return null;
    }

    // Stops come from the nearest gradient that has any.
    final stopElements = chain
        .map((e) => e.childElements.where((c) => c.name.local == 'stop').toList())
        .firstWhere((s) => s.isNotEmpty, orElse: () => []);
    final stops = <GradientStop>[];
    var last = 0.0;
    for (final stop in stopElements) {
      final (_, own) = _computeStyle(stop, const {});
      final raw = stop.getAttribute('offset')?.trim() ?? '0';
      var offset = raw.endsWith('%')
          ? (double.tryParse(raw.substring(0, raw.length - 1)) ?? 0) / 100
          : double.tryParse(raw) ?? 0;
      offset = offset.clamp(last, 1.0); // offsets never go backwards
      last = offset;
      final c = parseColor(own['stop-color'] ?? 'black') ?? InkColor.black;
      final o = (double.tryParse(own['stop-opacity'] ?? '') ?? 1).clamp(0.0, 1.0);
      stops.add(GradientStop(offset, c.withAlpha(c.alpha * o * alpha)));
    }
    if (stops.isEmpty) return null;
    if (stops.length == 1) return stops.single.color;

    final boxUnits = attr('gradientUnits') != 'userSpaceOnUse';
    if (boxUnits && (box.width <= 0 || box.height <= 0)) {
      // A gradient relative to a flat shape is undefined; use its middle color.
      return InkGradient(stops: stops).representativeColor;
    }
    double coord(String name, String fallback, {required double percentOf}) {
      final v = (attr(name) ?? fallback).trim();
      if (boxUnits) {
        return v.endsWith('%') ? (double.tryParse(v.substring(0, v.length - 1)) ?? 0) / 100 : double.tryParse(v) ?? 0;
      }
      return parseLength(v, percentOf: percentOf) ?? 0;
    }

    var transform = parseTransform(attr('gradientTransform'));
    if (boxUnits) transform = transform.then(_boxTransform(box));
    transform = transform.then(ctm);

    final spread = switch (attr('spreadMethod')) {
      'reflect' => SpreadMethod.reflect,
      'repeat' => SpreadMethod.repeat,
      _ => SpreadMethod.pad,
    };

    final GradientGeometry geometry;
    final GradientType type;
    if (g.name.local == 'linearGradient') {
      type = GradientType.linear;
      geometry = GradientGeometry(
        Offset(coord('x1', '0%', percentOf: _viewWidth), coord('y1', '0%', percentOf: _viewHeight)),
        Offset(coord('x2', '100%', percentOf: _viewWidth), coord('y2', '0%', percentOf: _viewHeight)),
        transform: transform,
      );
    } else {
      type = GradientType.radial;
      final c = Offset(coord('cx', '50%', percentOf: _viewWidth), coord('cy', '50%', percentOf: _viewHeight));
      final r = coord('r', '50%', percentOf: _viewDiagonal);
      final f = Offset(
        attr('fx') == null ? c.dx : coord('fx', '50%', percentOf: _viewWidth),
        attr('fy') == null ? c.dy : coord('fy', '50%', percentOf: _viewHeight),
      );
      if (r <= 0) return stops.last.color; // SVG: zero radius paints the last stop
      geometry = GradientGeometry(c, c + Offset(r, 0), focal: f == c ? null : f, transform: transform);
    }
    return InkGradient(type: type, stops: stops, spread: spread, geometry: geometry);
  }
}
