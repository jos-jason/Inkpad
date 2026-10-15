import 'dart:ui';

import 'units.dart';

/// A named measurement (Make mode), e.g. thickness = 12 mm. Size fields
/// accept its name in sums ("width/2 - thickness"), and shapes sized that
/// way follow when it changes.
class MakeVariable {
  String name;

  /// As typed, e.g. "12", "1/2\"", "width - 2*thickness".
  String expression;

  /// The unit plain numbers in [expression] are in (the drawing's unit when
  /// it was typed), so changing the drawing's units doesn't change it.
  String unit;

  /// A plain number (a count, a ratio) rather than a length.
  bool isNumber;

  MakeVariable({required this.name, required this.expression, this.unit = 'mm', this.isNumber = false});

  static final namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Words that already mean units, so can't be names.
  static const reserved = {'mm', 'cm', 'm', 'in', 'inch', 'inches', 'ft', 'feet', 'foot', 'pt', 'px'};

  static bool validName(String name) => namePattern.hasMatch(name) && !reserved.contains(name.toLowerCase());

  Map<String, dynamic> toJson() => {'name': name, 'expr': expression, 'unit': unit, if (isNumber) 'number': true};

  factory MakeVariable.fromJson(Map<String, dynamic> j) => MakeVariable(
        name: j['name'] as String,
        expression: j['expr'] as String,
        unit: j['unit'] as String? ?? 'mm',
        isNumber: j['number'] as bool? ?? false,
      );
}

/// A size or position typed as a sum using named measurements: its text,
/// the unit plain numbers are in, and the value it gave (in points). When
/// the shape is changed by other means its value no longer matches, and
/// the formula is forgotten.
class Formula {
  final String text;
  final String unit;
  final double value;

  const Formula(this.text, this.unit, this.value);

  /// Whether [current] is still what this formula gave.
  bool matches(double current) => (current - value).abs() <= 1e-6 * (1 + value.abs());

  Formula withValue(double v) => Formula(text, unit, v);

  Map<String, dynamic> toJson() => {'text': text, 'unit': unit, 'value': value};

  factory Formula.fromJson(Map<String, dynamic> j) =>
      Formula(j['text'] as String, j['unit'] as String? ?? 'mm', (j['value'] as num).toDouble());

  /// Renames the measurement [from] to [to] in [text] (whole words only).
  static String rename(String text, String from, String to) =>
      text.replaceAll(RegExp('(?<![A-Za-z0-9_])${RegExp.escape(from)}(?![A-Za-z0-9_])', caseSensitive: false), to);
}

/// Where a pinned shape keeps itself along one direction, relative to the
/// shape it's pinned to: a distance from its start (left/top) edge, its
/// end (right/bottom) edge, or centred on it (offset by the distance).
enum PinSide { start, center, end }

/// Keeps a shape in place relative to another (its target): e.g. 37 mm
/// from the panel's left edge and centred top to bottom. When the target
/// moves or is resized the shape follows; when the shape itself is moved
/// the distances change to match. Distances are between bounding boxes.
class Pin {
  /// The target's [InkElement.id].
  final String target;

  final PinSide? horizontal, vertical;

  /// Distances in points (from the edge, or the centre's offset), and
  /// their formulas when typed with named measurements.
  double dx, dy;
  Formula? dxFormula, dyFormula;

  /// The target's bounds when last checked (not saved): when they change,
  /// the shape follows.
  Rect? lastTarget;

  Pin({required this.target, this.horizontal, this.vertical, this.dx = 0, this.dy = 0, this.dxFormula, this.dyFormula});

  /// The distance along one direction from [target] to [own] bounds.
  static double distance(PinSide side, double ownStart, double ownEnd, double targetStart, double targetEnd) => switch (side) {
        PinSide.start => ownStart - targetStart,
        PinSide.end => targetEnd - ownEnd,
        PinSide.center => (ownStart + ownEnd) / 2 - (targetStart + targetEnd) / 2,
      };

  /// How far [own] must move to keep its distances to [target].
  Offset correction(Rect own, Rect target) {
    var mx = 0.0, my = 0.0;
    final h = horizontal, v = vertical;
    if (h != null) mx = _move(h, dx, own.left, own.right, target.left, target.right);
    if (v != null) my = _move(v, dy, own.top, own.bottom, target.top, target.bottom);
    return Offset(mx, my);
  }

  static double _move(PinSide side, double d, double s0, double s1, double t0, double t1) {
    final now = distance(side, s0, s1, t0, t1);
    // Distances from the end edge grow as the shape moves the other way.
    return side == PinSide.end ? now - d : d - now;
  }

  /// Takes the distances [own] is at now.
  void adopt(Rect own, Rect target) {
    final h = horizontal, v = vertical;
    if (h != null) {
      dx = distance(h, own.left, own.right, target.left, target.right);
      if (dxFormula != null && !dxFormula!.matches(dx)) dxFormula = null;
    }
    if (v != null) {
      dy = distance(v, own.top, own.bottom, target.top, target.bottom);
      if (dyFormula != null && !dyFormula!.matches(dy)) dyFormula = null;
    }
  }

  Map<String, dynamic> toJson() => {
        'target': target,
        if (horizontal != null) 'h': horizontal!.name,
        if (vertical != null) 'v': vertical!.name,
        'dx': dx,
        'dy': dy,
        if (dxFormula != null) 'dxf': dxFormula!.toJson(),
        if (dyFormula != null) 'dyf': dyFormula!.toJson(),
      };

  factory Pin.fromJson(Map<String, dynamic> j) => Pin(
        target: j['target'] as String,
        horizontal: j['h'] == null ? null : PinSide.values.byName(j['h'] as String),
        vertical: j['v'] == null ? null : PinSide.values.byName(j['v'] as String),
        dx: (j['dx'] as num?)?.toDouble() ?? 0,
        dy: (j['dy'] as num?)?.toDouble() ?? 0,
        dxFormula: j['dxf'] == null ? null : Formula.fromJson(j['dxf']),
        dyFormula: j['dyf'] == null ? null : Formula.fromJson(j['dyf']),
      );
}

/// Evaluates sums that use [variables] (by name, ignoring case), guarding
/// against measurements defined in terms of each other in a loop.
class VariableScope {
  final List<MakeVariable> variables;
  final _busy = <String>{};

  VariableScope(this.variables);

  MakeVariable? find(String name) {
    final n = name.toLowerCase();
    for (final v in variables) {
      if (v.name.toLowerCase() == n) return v;
    }
    return null;
  }

  /// A measurement's value: points for lengths, the number itself
  /// otherwise; null if it isn't defined or can't be worked out.
  ({double value, bool length})? lookup(String name) {
    final v = find(name);
    if (v == null) return null;
    final key = v.name.toLowerCase();
    if (!_busy.add(key)) return null; // defined in terms of itself
    try {
      final value = v.isNumber
          ? LengthFormat(unit: 'pt', variables: lookup).parse(v.expression)
          : LengthFormat(unit: v.unit, variables: lookup).parse(v.expression);
      return value == null ? null : (value: value, length: !v.isNumber);
    } finally {
      _busy.remove(key);
    }
  }

  /// [f]'s value now, in points; null if it can't be worked out.
  double? evaluate(Formula f) => LengthFormat(unit: f.unit, variables: lookup).parse(f.text);
}
