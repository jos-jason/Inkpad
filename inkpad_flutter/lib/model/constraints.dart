import 'rules.dart';

/// What a constraint can refer to on a shape.
enum GeoKind { point, line, circle }

/// A point, straight edge or circle of a shape, by the shape's
/// [InkElement.id] and an index:
/// - plain paths: point i is node i; line i the straight segment from node
///   i to the next;
/// - live rectangles: points 0–3 the corners (top-left, top-right,
///   bottom-right, bottom-left of its own box), 4 the centre; lines 0–3
///   the top, right, bottom and left sides;
/// - live lines: points 0 and 1 the ends, 2 the middle; line 0;
/// - live circles: point 0 the centre; circle 0;
/// - live ellipses: point 0 the centre;
/// - live polygons and stars: point 0 the centre, then the corners from 1;
///   lines i between corners i+1 and i+2.
class GeoRef {
  final String element;
  final GeoKind kind;
  final int index;

  const GeoRef(this.element, this.kind, this.index);

  @override
  bool operator ==(Object other) => other is GeoRef && other.element == element && other.kind == kind && other.index == index;

  @override
  int get hashCode => Object.hash(element, kind, index);

  Map<String, dynamic> toJson() => {'e': element, 'k': kind.name, 'i': index};

  factory GeoRef.fromJson(Map<String, dynamic> j) => GeoRef(j['e'] as String, GeoKind.values.byName(j['k'] as String), j['i'] as int);
}

/// The kinds of sketch constraint. Dimensions ([distance] … [diameter])
/// carry a value.
enum ConstraintType {
  coincident('Coincident', '×'),
  pointOnLine('On line', '×'),
  pointOnCircle('On circle', '×'),
  horizontal('Horizontal', 'H'),
  vertical('Vertical', 'V'),
  parallel('Parallel', '∥'),
  perpendicular('Perpendicular', '⊥'),
  collinear('Collinear', '⋯'),
  equal('Equal', '='),
  tangent('Tangent', 'T'),
  concentric('Concentric', '◎'),
  midpoint('Midpoint', '△'),
  symmetric('Symmetric', '⌯'),
  fix('Fixed', '🔒'),
  distance('Distance', ''),
  horizontalDistance('Horizontal distance', ''),
  verticalDistance('Vertical distance', ''),
  angle('Angle', ''),
  radius('Radius', ''),
  diameter('Diameter', '');

  final String label, glyph;

  const ConstraintType(this.label, this.glyph);

  bool get isDimension => index >= ConstraintType.distance.index;
}

/// A relationship the sketch solver keeps between shapes' points, edges
/// and circles (Make mode), like a CAD sketch's constraints.
class SketchConstraint {
  final ConstraintType type;
  final List<GeoRef> refs;

  /// Dimensions: the length (points) or angle (degrees) it holds, and its
  /// formula when typed with named measurements.
  double value;
  Formula? formula;

  /// A dimension that only shows a measurement (it doesn't drive the
  /// geometry), as when it would over-constrain the sketch.
  bool reference;

  /// Which way round the solution goes, chosen when it's made: tangent
  /// circles inside or outside each other, the side a horizontal or
  /// vertical distance is measured to, an angle's turn.
  double sign;

  /// Fix: where its geometry is held (x, y pairs, then a radius).
  List<double> fixed;

  SketchConstraint(this.type, this.refs, {this.value = 0, this.formula, this.reference = false, this.sign = 1, List<double>? fixed})
      : fixed = fixed ?? [];

  Set<String> get elements => {for (final r in refs) r.element};

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'refs': [for (final r in refs) r.toJson()],
        if (type.isDimension) 'value': value,
        if (formula != null) 'formula': formula!.toJson(),
        if (reference) 'reference': true,
        if (sign != 1) 'sign': sign,
        if (fixed.isNotEmpty) 'fixed': fixed,
      };

  factory SketchConstraint.fromJson(Map<String, dynamic> j) => SketchConstraint(
        ConstraintType.values.byName(j['type'] as String),
        [for (final r in j['refs'] as List) GeoRef.fromJson(r)],
        value: (j['value'] as num?)?.toDouble() ?? 0,
        formula: j['formula'] == null ? null : Formula.fromJson(j['formula']),
        reference: j['reference'] as bool? ?? false,
        sign: (j['sign'] as num?)?.toDouble() ?? 1,
        fixed: [for (final v in (j['fixed'] as List?) ?? const []) (v as num).toDouble()],
      );
}
