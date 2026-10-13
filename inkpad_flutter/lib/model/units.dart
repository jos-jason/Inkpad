import 'dart:math' as math;

/// Reading and writing physical lengths. Drawings are stored in points
/// (1/72 inch, as in Inkpad); this shows and accepts millimetres (with
/// fractions of a millimetre), centimetres, inches (decimal or fractional,
/// e.g. 1 3/8"), feet and points.
class LengthFormat {
  /// 'mm', 'cm', 'in', 'pt' or 'px'.
  final String unit;

  /// Inches as fractions (1 3/8") rather than decimals (1.375").
  final bool fractions;

  /// The smallest fraction of an inch shown: 8, 16, 32 or 64.
  final int denominator;

  /// Decimal places for other units (mm: 2 shows 0.05 mm).
  final int decimals;

  const LengthFormat({this.unit = 'mm', this.fractions = false, this.denominator = 32, this.decimals = 2});

  static const pointsPer = {
    'mm': 72 / 25.4,
    'cm': 72 / 2.54,
    'in': 72.0,
    'ft': 864.0,
    'pt': 1.0,
    'px': 1.0,
  };

  double get pointsPerUnit => pointsPer[unit] ?? 1;

  /// [points] as text in this unit, e.g. "12.5 mm", "1 3/8″".
  String format(double points, {bool withUnit = true}) {
    final v = points / pointsPerUnit;
    if (unit == 'in' && fractions) return _fraction(v, withUnit: withUnit);
    final text = _decimal(v, decimals);
    if (!withUnit) return text;
    return unit == 'in' ? '$text″' : '$text $unit';
  }

  static String _decimal(double v, int places) {
    var s = v.toStringAsFixed(places);
    if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s == '-0' ? '0' : s;
  }

  /// Inches to the nearest 1/[denominator], reduced (3/8 not 12/32); "≈"
  /// when the value isn't exactly that fraction.
  String _fraction(double inches, {required bool withUnit}) {
    final sign = inches < 0 ? '-' : '';
    final a = inches.abs();
    var n = (a * denominator).round();
    final approximate = (n / denominator - a).abs() > 1e-6;
    final whole = n ~/ denominator;
    n %= denominator;
    var d = denominator;
    while (n > 0 && n.isEven && d > 1) {
      n ~/= 2;
      d ~/= 2;
    }
    final text = n == 0 ? '$whole' : (whole == 0 ? '$n/$d' : '$whole $n/$d');
    return '${approximate ? '≈' : ''}$sign$text${withUnit ? '″' : ''}';
  }

  /// A length typed by the user, in points; null if it can't be read.
  /// Plain numbers are in this unit; others can be given ("25.4mm", "1in",
  /// 3/8", 1 3/8", 1-3/8", 2' 6"). Simple sums work: "300-2*12",
  /// "(600 - 18) / 2".
  double? parse(String text) {
    final v = _Expression(text, unit).evaluate();
    return v == null || !v.isFinite ? null : v * pointsPerUnit;
  }
}

/// Evaluates a length expression in [unit] units.
class _Expression {
  final String unit;
  final List<_Token> _tokens;
  int _i = 0;

  _Expression(String text, this.unit) : _tokens = _tokenize(text, unit);

  static const _suffixes = {
    'mm': 'mm', 'cm': 'cm', 'm': 'm', 'in': 'in', '"': 'in', '″': 'in', 'inch': 'in', 'inches': 'in',
    'ft': 'ft', "'": 'ft', '′': 'ft', 'feet': 'ft', 'foot': 'ft', 'pt': 'pt', 'px': 'px',
  };

  static double _unitValue(String suffix, String into) {
    final pts = suffix == 'm' ? 72 / 0.0254 : LengthFormat.pointsPer[suffix]!;
    return pts / (LengthFormat.pointsPer[into] ?? 1);
  }

  static List<_Token>? _tokenizeOrNull(String text, String unit) {
    final s = text.trim().toLowerCase().replaceAll(',', '.');
    final tokens = <_Token>[];
    var i = 0;
    // A number, a mixed number (1 3/8, 1-3/8) or a fraction (3/8).
    final numberRe = RegExp(r'(\d+(?:\.\d*)?|\.\d+)(?:(?:\s+|-)(\d+)/(\d+)|/(\d+))?');
    final suffixRe = RegExp(r'\s*(inches|inch|feet|foot|mm|cm|in|ft|pt|px|m(?![a-z])|"|″|' "'" r'|′)');
    while (i < s.length) {
      final ch = s[i];
      if (ch == ' ' || ch == '\t') {
        i++;
        continue;
      }
      if ('+-*/×÷()'.contains(ch)) {
        tokens.add(_Token.op(switch (ch) { '×' => '*', '÷' => '/', _ => ch }));
        i++;
        continue;
      }
      final m = numberRe.matchAsPrefix(s, i);
      if (m == null) return null;
      var value = double.parse(m.group(1)!);
      if (m.group(2) != null) {
        // A mixed number only directly after a whole number: 1 3/8, 1-3/8.
        final den = double.parse(m.group(3)!);
        if (den == 0) return null;
        value += double.parse(m.group(2)!) / den;
      } else if (m.group(4) != null) {
        final den = double.parse(m.group(4)!);
        if (den == 0) return null;
        value /= den;
      }
      i = m.end;
      final sm = suffixRe.matchAsPrefix(s, i);
      var hasUnit = false;
      if (sm != null) {
        value *= _unitValue(_suffixes[sm.group(1)!]!, unit);
        i = sm.end;
        hasUnit = true;
      }
      // 2' 6": lengths side by side add up.
      if (tokens.isNotEmpty && tokens.last.isNumber && tokens.last.hasUnit && hasUnit) tokens.add(const _Token.op('+'));
      tokens.add(_Token.number(value, hasUnit: hasUnit));
    }
    return tokens;
  }

  static List<_Token> _tokenize(String text, String unit) => _tokenizeOrNull(text, unit) ?? const [_Token.op('?')];

  double? evaluate() {
    if (_tokens.isEmpty) return null;
    try {
      final v = _sum();
      return _i == _tokens.length ? v : null;
    } on FormatException {
      return null;
    }
  }

  _Token? get _peek => _i < _tokens.length ? _tokens[_i] : null;

  double _sum() {
    var v = _product();
    while (_peek?.op == '+' || _peek?.op == '-') {
      final op = _tokens[_i++].op;
      final r = _product();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double _product() {
    var v = _unary();
    while (_peek?.op == '*' || _peek?.op == '/') {
      final op = _tokens[_i++].op;
      final r = _unary();
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  double _unary() {
    if (_peek?.op == '-') {
      _i++;
      return -_unary();
    }
    if (_peek?.op == '+') {
      _i++;
      return _unary();
    }
    final t = _peek;
    if (t == null) throw const FormatException();
    if (t.op == '(') {
      _i++;
      final v = _sum();
      if (_peek?.op != ')') throw const FormatException();
      _i++;
      return v;
    }
    if (!t.isNumber) throw const FormatException();
    _i++;
    return t.value;
  }
}

class _Token {
  final String? op;
  final double value;
  final bool hasUnit;

  const _Token.op(this.op)
      : value = 0,
        hasUnit = false;
  const _Token.number(this.value, {this.hasUnit = false}) : op = null;

  bool get isNumber => op == null;
}

/// Angles typed as numbers of degrees (with sums).
double? parseDegrees(String text) => _Expression(text.replaceAll('°', ''), 'pt').evaluate();

/// [degrees] tidily, e.g. "45°", "12.5°".
String formatDegrees(double degrees) {
  var d = degrees % 360;
  if (d > 180) d -= 360;
  return '${LengthFormat._decimal(d, 2)}°';
}

/// Rounds [v] to [places] decimals (to keep typed values exact).
double roundTo(double v, int places) {
  final f = math.pow(10, places);
  return (v * f).round() / f;
}
