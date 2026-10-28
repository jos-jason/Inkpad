import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import '../svg/svg_importer.dart';
import '../svg/svg_values.dart';
import 'ai_client.dart';

/// The drawing (or the selection) described for an AI model: compact JSON
/// with an id per element, so its edits can name what to change.
class DrawingBrief {
  final Map<String, InkElement> byId;
  final List<String> selectedIds;
  final String json;

  /// Elements left out to keep the request small.
  final int omitted;

  DrawingBrief._(this.byId, this.selectedIds, this.json, this.omitted);

  /// Everything in the visible layers (up to [maxElements]), with the
  /// selection marked.
  factory DrawingBrief.of(DrawingController c, {int maxElements = 250}) {
    final byId = <String, InkElement>{};
    final ids = <InkElement, String>{};
    var omitted = 0;

    Object? describe(InkElement e) {
      if (byId.length >= maxElements) {
        omitted++;
        return null;
      }
      final id = 'e${byId.length + 1}';
      byId[id] = e;
      ids[e] = id;
      final b = e.bounds;
      final out = <String, Object?>{'id': id, 'type': _type(e), 'box': [_r(b.left), _r(b.top), _r(b.width), _r(b.height)]};
      if (e is InkPath) {
        out['shape'] = _shapeKind(e);
        if (e.svgPathData.length <= 300) out['d'] = e.svgPathData;
      }
      if (e is InkStylable) {
        out['fill'] = _paint(e.fill);
        final s = e.stroke;
        if (s != null && s.willRender) {
          out['stroke'] = {
            'color': _paint(s.paint),
            'width': _r(s.width),
            if (s.dashPattern.isNotEmpty) 'dash': s.dashPattern,
            if (s.startArrow.isNotEmpty) 'start_arrow': s.startArrow,
            if (s.endArrow.isNotEmpty) 'end_arrow': s.endArrow,
          };
        }
      }
      if (e is InkText) {
        out['text'] = e.text;
        out['font'] = {'family': e.fontFamily, 'style': e.fontStyle, 'size': _r(e.fontSize), 'align': e.alignment.name};
      }
      if (e is InkTextPath) {
        out['text'] = e.text;
        out['font'] = {'family': e.fontFamily, 'style': e.fontStyle, 'size': _r(e.fontSize)};
      }
      if (e.opacity < 1) out['opacity'] = _r(e.opacity, 2);
      final sh = e.shadow;
      if (sh != null) out['shadow'] = {'color': sh.color.hexValue, 'blur': _r(sh.radius), 'offset': _r(sh.offset), 'angle': _r(sh.angle)};
      if (e.blendMode != InkBlendMode.normal) out['blend'] = e.blendMode.css;
      if (e is InkGroup) out['children'] = [for (final x in e.elements) ?describe(x)];
      if (e is InkStylable && e.isMasking) out['clips'] = [for (final x in e.maskedElements) ?describe(x)];
      return out;
    }

    final d = c.drawing;
    final layers = [
      for (final l in d.layers)
        if (l.visible)
          {
            'layer': l.name,
            if (l.locked) 'locked': true,
            'elements': [for (final e in l.elements) ?describe(e)],
          },
    ];
    final selected = [for (final e in c.selection) ?ids[e]];
    final json = jsonEncode({
      'page': {'width': _r(d.width), 'height': _r(d.height)},
      'selected': selected,
      'layers': layers,
      if (omitted > 0) 'omitted_elements': omitted,
    });
    return DrawingBrief._(byId, selected, json, omitted);
  }

  /// The colors used in the drawing, most common first (for matching styles).
  static List<String> palette(InkDrawing d, {int max = 8}) {
    final counts = <String, int>{};
    void add(InkPaint? p) {
      if (p is InkColor) counts[p.hexValue] = (counts[p.hexValue] ?? 0) + 1;
      if (p is InkGradient) {
        for (final s in p.stops) {
          counts[s.color.hexValue] = (counts[s.color.hexValue] ?? 0) + 1;
        }
      }
    }

    for (final e in d.allElements) {
      for (final x in e.selfAndDescendants) {
        if (x is InkStylable) {
          add(x.fill);
          add(x.stroke?.paint);
        }
      }
    }
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in sorted.take(max)) e.key];
  }

  static String _type(InkElement e) => switch (e) {
        InkText() => 'text',
        InkTextPath() => 'text_on_path',
        InkImage() => 'image',
        InkGroup() => 'group',
        InkCompoundPath() => 'compound_shape',
        _ => 'shape',
      };

  static String _shapeKind(InkPath p) {
    final n = p.nodes;
    final straight = n.every((x) => !x.hasInPoint && !x.hasOutPoint);
    if (!p.closed) return n.length == 2 && straight ? 'line' : 'open_path';
    if (n.length == 4 && straight) {
      final xs = {for (final x in n) x.anchorPoint.dx.toStringAsFixed(2)}, ys = {for (final x in n) x.anchorPoint.dy.toStringAsFixed(2)};
      if (xs.length == 2 && ys.length == 2) return 'rectangle';
    }
    if (n.length == 4 && !straight) return 'ellipse';
    if (straight) return 'polygon';
    return 'path';
  }

  static Object _paint(InkPaint? p) => switch (p) {
        null => 'none',
        InkColor c => c.alpha < 1 ? '${c.hexValue} (opacity ${_r(c.alpha, 2)})' : c.hexValue,
        InkGradient g => {'gradient': g.type.name, 'colors': [for (final s in g.stops) s.color.hexValue]},
        _ => 'none',
      };

  static num _r(double v, [int digits = 1]) {
    final f = math.pow(10, digits);
    final r = (v * f).round() / f;
    return r == r.roundToDouble() ? r.round() : r;
  }
}

/// The tool an editing model calls: a list of operations.
final editTool = AiTool(
  'edit_drawing',
  'Change the drawing. Operations run in order; ids come from the drawing JSON.',
  {
    'type': 'object',
    'properties': {
      'summary': {'type': 'string', 'description': 'One short sentence for the user saying what was done (or why nothing was).'},
      'operations': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'op': {
              'type': 'string',
              'enum': [
                'fill', 'stroke', 'opacity', 'shadow', 'move', 'place', 'resize', 'rotate', 'flip', 'align',
                'distribute', 'order', 'group', 'ungroup', 'duplicate', 'delete', 'text', 'font', 'add_svg',
              ],
            },
            'ids': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Elements to change.'},
            'color': {'type': 'string', 'description': '#rrggbb, a CSS color name, or "none".'},
            'gradient': {
              'type': 'object',
              'properties': {
                'type': {'type': 'string', 'enum': ['linear', 'radial']},
                'colors': {'type': 'array', 'items': {'type': 'string'}},
                'angle': {'type': 'number', 'description': 'Linear only: degrees, 0 = left to right, 90 = top to bottom.'},
              },
            },
            'width': {'type': 'number'},
            'height': {'type': 'number'},
            'dash': {'type': 'array', 'items': {'type': 'number'}},
            'start_arrow': {'type': 'string'},
            'end_arrow': {'type': 'string'},
            'opacity': {'type': 'number', 'description': '0 to 1.'},
            'blur': {'type': 'number'},
            'offset': {'type': 'number'},
            'angle': {'type': 'number'},
            'dx': {'type': 'number'},
            'dy': {'type': 'number'},
            'x': {'type': 'number'},
            'y': {'type': 'number'},
            'degrees': {'type': 'number', 'description': 'Clockwise.'},
            'axis': {'type': 'string', 'enum': ['horizontal', 'vertical']},
            'edge': {'type': 'string', 'enum': ['left', 'center', 'right', 'top', 'middle', 'bottom']},
            'to': {'type': 'string', 'enum': ['front', 'back', 'forward', 'backward']},
            'text': {'type': 'string'},
            'font': {'type': 'string'},
            'style': {'type': 'string', 'description': 'e.g. Regular, Bold, Italic, Bold Italic.'},
            'size': {'type': 'number'},
            'align': {'type': 'string', 'enum': ['left', 'center', 'right']},
            'svg': {'type': 'string', 'description': 'add_svg: a complete <svg> document of new artwork.'},
          },
          'required': ['op'],
        },
      },
    },
    'required': ['summary', 'operations'],
  },
);

/// Inkpad's arrowheads, for the edit instructions.
const arrowNames = 'arrow1, arrow2, arrow3, T shape, closed circle, closed square, closed diamond, open circle, open square, '
    'open diamond, chubby arrow, chubby notched, chubby open';

/// What applying a model's edits did.
class AiEditResult {
  final String summary;
  final int applied;
  final List<String> problems;

  const AiEditResult(this.summary, this.applied, this.problems);
}

/// Applies a model's operations to the drawing, as one undo step. Unknown
/// ids and bad values are skipped (and reported), never fatal.
AiEditResult applyEdits(DrawingController c, DrawingBrief brief, Map<String, dynamic> answer) {
  final ops = (answer['operations'] as List?)?.whereType<Map>().toList() ?? const [];
  final summary = (answer['summary'] as String?)?.trim() ?? '';
  final problems = <String>[];
  var applied = 0;
  if (ops.isEmpty) return AiEditResult(summary.isEmpty ? 'The AI made no changes.' : summary, 0, problems);

  c.batch(() {
    for (final raw in ops.take(300)) {
      final op = Map<String, dynamic>.from(raw);
      try {
        if (_apply(c, brief, op, problems)) applied++;
      } catch (e) {
        problems.add('Skipped ${op['op']}: $e');
      }
    }
  });
  return AiEditResult(summary, applied, problems);
}

double? _num(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

InkColor? _color(Object? v) => v is String ? parseColor(v.trim()) : null;

bool _apply(DrawingController c, DrawingBrief brief, Map<String, dynamic> op, List<String> problems) {
  final name = op['op'] as String? ?? '';
  final targets = <InkElement>[];
  for (final id in (op['ids'] as List? ?? const [])) {
    final e = brief.byId[id.toString()];
    if (e == null) {
      problems.add('Unknown element $id');
    } else {
      targets.add(e);
    }
  }
  if (name != 'add_svg' && targets.isEmpty) {
    problems.add('Nothing to $name');
    return false;
  }
  // Shapes inside groups take styles too.
  Iterable<InkStylable> stylables() => targets.expand((e) => e is InkGroup ? e.selfAndDescendants.whereType<InkStylable>() : [if (e is InkStylable) e]);
  Rect bounds() => targets.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));
  // Top-level elements, for commands that work on the selection.
  void selectTopLevel() {
    final top = [for (final e in targets) if (c.layerOf(e) != null) e];
    c.selection
      ..clear()
      ..addAll(top);
    if (top.length < targets.length) problems.add('$name only works on elements directly in a layer');
  }

  switch (name) {
    case 'fill':
      final paint = _paintFrom(op);
      if (paint == _invalid) {
        problems.add('No usable fill color');
        return false;
      }
      for (final s in stylables()) {
        s.fill = paint is InkGradient && op['gradient']?['type'] != 'radial' ? _angled(paint, s.bounds, _num(op['gradient']?['angle']) ?? 0) : paint as InkPaint?;
        if (s is InkText) s.runs = s.runs.restyleAll((st) => st.without(fill: true));
      }
    case 'stroke':
      final colorValue = op['color'];
      for (final s in stylables()) {
        if (colorValue == 'none') {
          s.stroke = null;
          continue;
        }
        var st = s.stroke ?? const StrokeStyle(width: 1);
        final paint = op.containsKey('gradient') ? _paintFrom(op) : null;
        if (paint is InkGradient) {
          st = st.withPaint(paint);
        } else if (_color(colorValue) case final col?) {
          st = st.withPaint(col);
        }
        if (_num(op['width']) case final w?) st = st.copyWith(width: w.clamp(0.1, 500));
        if (op['dash'] is List) st = st.copyWith(dashPattern: [for (final d in op['dash'] as List) ?_num(d)]);
        if (op['start_arrow'] is String) st = st.copyWith(startArrow: _arrow(op['start_arrow']));
        if (op['end_arrow'] is String) st = st.copyWith(endArrow: _arrow(op['end_arrow']));
        s.stroke = st;
      }
    case 'opacity':
      final v = _num(op['opacity']);
      if (v == null) return false;
      for (final e in targets) {
        e.opacity = (v > 1 ? v / 100 : v).clamp(0.0, 1.0);
      }
    case 'shadow':
      for (final e in targets) {
        if (op['color'] == 'none') {
          e.shadow = null;
          continue;
        }
        final base = e.shadow ?? const InkShadow();
        e.shadow = base.copyWith(
          color: _color(op['color']) ?? base.color,
          radius: _num(op['blur'])?.clamp(0, 200),
          offset: _num(op['offset'])?.clamp(0, 500),
          angle: _num(op['angle']),
        );
      }
    case 'move':
      final t = Affine.translation(_num(op['dx']) ?? 0, _num(op['dy']) ?? 0);
      for (final e in targets) {
        e.transform(t);
      }
    case 'place':
      final b = bounds();
      final t = Affine.translation((_num(op['x']) ?? b.left) - b.left, (_num(op['y']) ?? b.top) - b.top);
      for (final e in targets) {
        e.transform(t);
      }
    case 'resize':
      final b = bounds();
      final w = _num(op['width']), h = _num(op['height']);
      if ((w == null && h == null) || b.width <= 0 || b.height <= 0) return false;
      var sx = w == null ? null : w / b.width, sy = h == null ? null : h / b.height;
      sx ??= sy;
      sy ??= sx;
      final t = Affine.scaleAbout(b.topLeft, sx!.clamp(0.01, 100), sy!.clamp(0.01, 100));
      for (final e in targets) {
        e.transform(t);
      }
    case 'rotate':
      final t = Affine.rotationAbout(bounds().center, (_num(op['degrees']) ?? 0) * math.pi / 180);
      for (final e in targets) {
        e.transform(t);
      }
    case 'flip':
      final horizontal = op['axis'] != 'vertical';
      final t = Affine.scaleAbout(bounds().center, horizontal ? -1 : 1, horizontal ? 1 : -1);
      for (final e in targets) {
        e.transform(t);
      }
    case 'align':
      final edge = AlignEdge.values.asNameMap()[op['edge']];
      if (edge == null) return false;
      selectTopLevel();
      c.align(edge);
    case 'distribute':
      selectTopLevel();
      c.distribute(horizontal: op['axis'] != 'vertical');
    case 'order':
      selectTopLevel();
      switch (op['to']) {
        case 'front':
          c.bringToFront();
        case 'back':
          c.sendToBack();
        case 'forward':
          c.bringForward();
        case 'backward':
          c.sendBackward();
        default:
          return false;
      }
    case 'group':
      selectTopLevel();
      c.groupSelection();
    case 'ungroup':
      selectTopLevel();
      c.ungroupSelection();
    case 'duplicate':
      selectTopLevel();
      c.duplicateInPlace();
      c.transformSelection(Affine.translation(_num(op['dx']) ?? 10, _num(op['dy']) ?? 10));
    case 'delete':
      for (final e in targets) {
        _remove(c.drawing, e);
        c.selection.remove(e);
      }
    case 'text':
      final text = op['text'];
      if (text is! String) return false;
      for (final e in targets) {
        if (e is InkText) e.text = text;
        if (e is InkTextPath) e.text = text.replaceAll('\n', ' ');
      }
    case 'font':
      for (final e in targets) {
        if (e is InkText) {
          if (op['font'] is String) e.fontFamily = op['font'];
          if (op['style'] is String) e.fontStyle = op['style'];
          if (_num(op['size']) case final s?) e.fontSize = s.clamp(1, 2000);
          if (TextAlignment.values.asNameMap()[op['align']] case final a?) e.alignment = a;
          e.runs = e.runs.restyleAll((st) => st.without(family: op['font'] is String, style: op['style'] is String, size: op['size'] != null));
        } else if (e is InkTextPath) {
          if (op['font'] is String) e.fontFamily = op['font'];
          if (op['style'] is String) e.fontStyle = op['style'];
          if (_num(op['size']) case final s?) e.fontSize = s.clamp(1, 2000);
        }
      }
    case 'add_svg':
      final svg = op['svg'];
      if (svg is! String) return false;
      final placed = placeSvg(c, svg, x: _num(op['x']), y: _num(op['y']), width: _num(op['width']), height: _num(op['height']));
      problems.addAll(placed);
    default:
      problems.add('Unknown operation $name');
      return false;
  }
  return true;
}

const _invalid = Object();

Object? _paintFrom(Map<String, dynamic> op) {
  final g = op['gradient'];
  if (g is Map) {
    final colors = [for (final x in (g['colors'] as List? ?? const [])) ?_color(x)];
    if (colors.length >= 2) {
      return InkGradient(
        type: g['type'] == 'radial' ? GradientType.radial : GradientType.linear,
        stops: [for (final (i, col) in colors.indexed) GradientStop(i / (colors.length - 1), col)],
      );
    }
  }
  if (op['color'] == 'none') return null;
  return _color(op['color']) ?? _invalid;
}

/// A linear gradient across [b] at [degrees] (0: left to right, 90: top to bottom).
InkGradient _angled(InkGradient g, Rect b, double degrees) {
  if (degrees == 0) return g;
  final a = degrees * math.pi / 180;
  final dir = Offset(math.cos(a), math.sin(a));
  final half = (b.width * dir.dx.abs() + b.height * dir.dy.abs()) / 2;
  return g.copyWith(geometry: GradientGeometry(b.center - dir * half, b.center + dir * half));
}

String _arrow(Object? name) {
  final s = name.toString().trim();
  if (s == 'none' || s.isEmpty) return '';
  const known = [
    'arrow1', 'arrow2', 'arrow3', 'T shape', 'closed circle', 'closed square', 'closed diamond', 'open circle', 'open square',
    'open diamond', 'chubby arrow', 'chubby notched', 'chubby open',
  ];
  return known.firstWhere((k) => k.toLowerCase() == s.toLowerCase(), orElse: () => 'arrow1');
}

void _remove(InkDrawing d, InkElement target) {
  bool fromList(List<InkElement> list) {
    if (list.remove(target)) return true;
    for (final e in list) {
      if (e is InkGroup && fromList(e.elements)) return true;
      if (e is InkStylable && fromList(e.maskedElements)) return true;
    }
    return false;
  }

  for (final l in d.layers) {
    if (fromList(l.elements)) return;
  }
}

/// Adds artwork from an SVG document to the drawing, selected. With a box
/// ([x], [y], [width], [height]) it's scaled to fit inside it, centered;
/// otherwise it keeps its own coordinates. Returns import notes.
List<String> placeSvg(DrawingController c, String svg, {double? x, double? y, double? width, double? height}) {
  final result = importSvg(svg);
  final art = result.drawing;
  final elements = art.allElements.toList();
  if (elements.isEmpty) return ['The artwork was empty', ...result.warnings];
  c.place(art);
  final placed = c.selection.toList();
  final b = placed.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));
  if (width != null && height != null && b.width > 0 && b.height > 0) {
    final s = math.min(width / b.width, height / b.height);
    final target = Offset((x ?? 0) + width / 2, (y ?? 0) + height / 2);
    final t = Affine.translation(-b.center.dx, -b.center.dy).then(Affine.scale(s, s)).then(Affine.translation(target.dx, target.dy));
    for (final e in placed) {
      e.transform(t);
    }
  } else if (x != null || y != null) {
    final t = Affine.translation((x ?? b.left) - b.left, (y ?? b.top) - b.top);
    for (final e in placed) {
      e.transform(t);
    }
  }
  return result.warnings;
}
