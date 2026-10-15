import 'dart:math' as math;
import 'dart:ui';

import '../model/geometry.dart';
import '../model/style.dart';

/// Parsers for SVG attribute values: colors, lengths, transforms, lists.
/// Ported in spirit from WDSVGStyleParser, WDSVGTransformParser and WDParseUtil.

final _numberRe = RegExp(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?');

List<double> parseNumberList(String? s) =>
    s == null ? [] : _numberRe.allMatches(s).map((m) => double.parse(m.group(0)!)).toList();

/// Pixels per unit (CSS 96 dpi, as used by current browsers and editors).
const _unitScale = {
  '': 1.0,
  'px': 1.0,
  'pt': 96 / 72,
  'pc': 16.0,
  'mm': 96 / 25.4,
  'cm': 96 / 2.54,
  'in': 96.0,
  'em': 16.0,
  'ex': 8.0,
};

final _lengthRe = RegExp(r'^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*([a-zA-Z%]*)\s*$');

/// Parses a length in user units. Percentages resolve against [percentOf];
/// returns null if [s] is missing, malformed, or a percentage with no reference.
double? parseLength(String? s, {double? percentOf}) {
  if (s == null) return null;
  final m = _lengthRe.firstMatch(s);
  if (m == null) return null;
  final value = double.parse(m.group(1)!);
  final unit = m.group(2)!.toLowerCase();
  if (unit == '%') return percentOf == null ? null : value / 100 * percentOf;
  final scale = _unitScale[unit];
  return scale == null ? null : value * scale;
}

final _transformRe = RegExp(r'(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)');

/// Parses a `transform` attribute. The returned transform maps the
/// element's coordinates into its parent's.
Affine parseTransform(String? s) {
  if (s == null) return Affine.identity;
  var total = Affine.identity;
  for (final m in _transformRe.allMatches(s)) {
    final a = parseNumberList(m.group(2));
    final t = switch (m.group(1)) {
      'matrix' when a.length >= 6 => Affine(a[0], a[1], a[2], a[3], a[4], a[5]),
      'translate' when a.isNotEmpty => Affine.translation(a[0], a.length > 1 ? a[1] : 0),
      'scale' when a.isNotEmpty => Affine.scale(a[0], a.length > 1 ? a[1] : a[0]),
      'rotate' when a.length >= 3 => Affine.rotationAbout(Offset(a[1], a[2]), _rad(a[0])),
      'rotate' when a.isNotEmpty => Affine.rotation(_rad(a[0])),
      'skewX' when a.isNotEmpty => Affine(1, 0, math.tan(_rad(a[0])), 1, 0, 0),
      'skewY' when a.isNotEmpty => Affine(1, math.tan(_rad(a[0])), 0, 1, 0, 0),
      _ => Affine.identity,
    };
    // "A B" applies B first, then A.
    total = t.then(total);
  }
  return total;
}

double _rad(double deg) => deg * math.pi / 180;

/// Result of parsing a paint (`fill` / `stroke`) value.
sealed class SvgPaint {
  const SvgPaint();
}

class SvgNoPaint extends SvgPaint {
  const SvgNoPaint();
}

class SvgColorPaint extends SvgPaint {
  final InkColor color;
  const SvgColorPaint(this.color);
}

class SvgCurrentColorPaint extends SvgPaint {
  const SvgCurrentColorPaint();
}

/// `url(#id)` with an optional fallback color.
class SvgUrlPaint extends SvgPaint {
  final String id;
  final SvgPaint? fallback;
  const SvgUrlPaint(this.id, this.fallback);
}

final _urlRe = RegExp(r'^url\(\s*["\x27]?#([^)"\x27]+)["\x27]?\s*\)\s*(.*)$');

SvgPaint? parsePaint(String? s) {
  if (s == null) return null;
  final v = s.trim();
  if (v.isEmpty || v == 'inherit') return null;
  if (v == 'none' || v == 'transparent') return const SvgNoPaint();
  if (v == 'currentColor' || v == 'currentcolor') return const SvgCurrentColorPaint();
  final url = _urlRe.firstMatch(v);
  if (url != null) {
    final rest = url.group(2)!.trim();
    return SvgUrlPaint(url.group(1)!, rest.isEmpty ? null : parsePaint(rest));
  }
  final c = parseColor(v);
  return c == null ? null : SvgColorPaint(c);
}

/// Parses a CSS color: #rgb, #rgba, #rrggbb, #rrggbbaa, rgb()/rgba() with
/// numbers or percentages, hsl()/hsla(), and the CSS named colors.
InkColor? parseColor(String? s) {
  if (s == null) return null;
  final v = s.trim().toLowerCase();
  if (v.startsWith('#')) return _hex(v.substring(1));
  final fn = RegExp(r'^(rgba?|hsla?)\s*\(([^)]*)\)$').firstMatch(v);
  if (fn != null) {
    final parts = fn.group(2)!.split(RegExp(r'[\s,/]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length < 3) return null;
    double comp(String p, double scale) =>
        p.endsWith('%') ? (double.tryParse(p.substring(0, p.length - 1)) ?? 0) / 100 : (double.tryParse(p) ?? 0) / scale;
    final alpha = parts.length > 3 ? comp(parts[3], 1).clamp(0.0, 1.0) : 1.0;
    if (fn.group(1)!.startsWith('rgb')) {
      return InkColor(
        comp(parts[0], 255).clamp(0.0, 1.0),
        comp(parts[1], 255).clamp(0.0, 1.0),
        comp(parts[2], 255).clamp(0.0, 1.0),
        alpha,
      );
    }
    final h = ((double.tryParse(parts[0].replaceAll('deg', '')) ?? 0) % 360) / 360;
    final sat = comp(parts[1], 100).clamp(0.0, 1.0), light = comp(parts[2], 100).clamp(0.0, 1.0);
    return _hsl(h, sat, light, alpha);
  }
  final hex = namedColors[v];
  return hex == null ? null : _hex(hex);
}

InkColor? _hex(String h) {
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(h)) return null;
  if (h.length == 3 || h.length == 4) h = h.split('').map((c) => '$c$c').join();
  if (h.length != 6 && h.length != 8) return null;
  double byte(int i) => int.parse(h.substring(i, i + 2), radix: 16) / 255;
  return InkColor(byte(0), byte(2), byte(4), h.length == 8 ? byte(6) : 1);
}

InkColor _hsl(double h, double s, double l, double a) {
  double hue(double p, double q, double t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }

  if (s == 0) return InkColor(l, l, l, a);
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  return InkColor(hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3), a);
}

/// Parses a `style="a: b; c: d"` declaration list.
Map<String, String> parseDeclarations(String? s) {
  final result = <String, String>{};
  if (s == null) return result;
  for (final decl in s.split(';')) {
    final colon = decl.indexOf(':');
    if (colon < 0) continue;
    final name = decl.substring(0, colon).trim().toLowerCase();
    var value = decl.substring(colon + 1).trim();
    value = value.replaceAll(RegExp(r'\s*!important\s*$'), '');
    if (name.isNotEmpty && value.isNotEmpty) result[name] = value;
  }
  return result;
}

/// The 148 CSS named colors.
const namedColors = {
  'aliceblue': 'f0f8ff', 'antiquewhite': 'faebd7', 'aqua': '00ffff', 'aquamarine': '7fffd4',
  'azure': 'f0ffff', 'beige': 'f5f5dc', 'bisque': 'ffe4c4', 'black': '000000',
  'blanchedalmond': 'ffebcd', 'blue': '0000ff', 'blueviolet': '8a2be2', 'brown': 'a52a2a',
  'burlywood': 'deb887', 'cadetblue': '5f9ea0', 'chartreuse': '7fff00', 'chocolate': 'd2691e',
  'coral': 'ff7f50', 'cornflowerblue': '6495ed', 'cornsilk': 'fff8dc', 'crimson': 'dc143c',
  'cyan': '00ffff', 'darkblue': '00008b', 'darkcyan': '008b8b', 'darkgoldenrod': 'b8860b',
  'darkgray': 'a9a9a9', 'darkgreen': '006400', 'darkgrey': 'a9a9a9', 'darkkhaki': 'bdb76b',
  'darkmagenta': '8b008b', 'darkolivegreen': '556b2f', 'darkorange': 'ff8c00', 'darkorchid': '9932cc',
  'darkred': '8b0000', 'darksalmon': 'e9967a', 'darkseagreen': '8fbc8f', 'darkslateblue': '483d8b',
  'darkslategray': '2f4f4f', 'darkslategrey': '2f4f4f', 'darkturquoise': '00ced1', 'darkviolet': '9400d3',
  'deeppink': 'ff1493', 'deepskyblue': '00bfff', 'dimgray': '696969', 'dimgrey': '696969',
  'dodgerblue': '1e90ff', 'firebrick': 'b22222', 'floralwhite': 'fffaf0', 'forestgreen': '228b22',
  'fuchsia': 'ff00ff', 'gainsboro': 'dcdcdc', 'ghostwhite': 'f8f8ff', 'gold': 'ffd700',
  'goldenrod': 'daa520', 'gray': '808080', 'green': '008000', 'greenyellow': 'adff2f',
  'grey': '808080', 'honeydew': 'f0fff0', 'hotpink': 'ff69b4', 'indianred': 'cd5c5c',
  'indigo': '4b0082', 'ivory': 'fffff0', 'khaki': 'f0e68c', 'lavender': 'e6e6fa',
  'lavenderblush': 'fff0f5', 'lawngreen': '7cfc00', 'lemonchiffon': 'fffacd', 'lightblue': 'add8e6',
  'lightcoral': 'f08080', 'lightcyan': 'e0ffff', 'lightgoldenrodyellow': 'fafad2', 'lightgray': 'd3d3d3',
  'lightgreen': '90ee90', 'lightgrey': 'd3d3d3', 'lightpink': 'ffb6c1', 'lightsalmon': 'ffa07a',
  'lightseagreen': '20b2aa', 'lightskyblue': '87cefa', 'lightslategray': '778899', 'lightslategrey': '778899',
  'lightsteelblue': 'b0c4de', 'lightyellow': 'ffffe0', 'lime': '00ff00', 'limegreen': '32cd32',
  'linen': 'faf0e6', 'magenta': 'ff00ff', 'maroon': '800000', 'mediumaquamarine': '66cdaa',
  'mediumblue': '0000cd', 'mediumorchid': 'ba55d3', 'mediumpurple': '9370db', 'mediumseagreen': '3cb371',
  'mediumslateblue': '7b68ee', 'mediumspringgreen': '00fa9a', 'mediumturquoise': '48d1cc', 'mediumvioletred': 'c71585',
  'midnightblue': '191970', 'mintcream': 'f5fffa', 'mistyrose': 'ffe4e1', 'moccasin': 'ffe4b5',
  'navajowhite': 'ffdead', 'navy': '000080', 'oldlace': 'fdf5e6', 'olive': '808000',
  'olivedrab': '6b8e23', 'orange': 'ffa500', 'orangered': 'ff4500', 'orchid': 'da70d6',
  'palegoldenrod': 'eee8aa', 'palegreen': '98fb98', 'paleturquoise': 'afeeee', 'palevioletred': 'db7093',
  'papayawhip': 'ffefd5', 'peachpuff': 'ffdab9', 'peru': 'cd853f', 'pink': 'ffc0cb',
  'plum': 'dda0dd', 'powderblue': 'b0e0e6', 'purple': '800080', 'rebeccapurple': '663399',
  'red': 'ff0000', 'rosybrown': 'bc8f8f', 'royalblue': '4169e1', 'saddlebrown': '8b4513',
  'salmon': 'fa8072', 'sandybrown': 'f4a460', 'seagreen': '2e8b57', 'seashell': 'fff5ee',
  'sienna': 'a0522d', 'silver': 'c0c0c0', 'skyblue': '87ceeb', 'slateblue': '6a5acd',
  'slategray': '708090', 'slategrey': '708090', 'snow': 'fffafa', 'springgreen': '00ff7f',
  'steelblue': '4682b4', 'tan': 'd2b48c', 'teal': '008080', 'thistle': 'd8bfd8',
  'tomato': 'ff6347', 'turquoise': '40e0d0', 'violet': 'ee82ee', 'wheat': 'f5deb3',
  'white': 'ffffff', 'whitesmoke': 'f5f5f5', 'yellow': 'ffff00', 'yellowgreen': '9acd32',
};
