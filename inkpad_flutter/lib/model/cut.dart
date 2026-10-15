import 'style.dart';

/// How a shape is cut (Make mode). These are Shaper Origin's cut types,
/// and the same ideas carry over to other CNC routers and laser cutters.
enum CutType {
  /// Cut around the outside of the shape: the part keeps its full size.
  exterior('Exterior', 'Cut around the outside'),

  /// Cut a hole matching the shape.
  interior('Interior', 'Cut out a hole'),

  /// Cut along the line itself (engraving, scoring).
  online('On line', 'Cut along the line'),

  /// Clear the area inside to a depth.
  pocket('Pocket', 'Clear the inside to a depth'),

  /// Reference only: never cut.
  guide('Guide', 'Not cut; for reference');

  final String label;
  final String description;

  const CutType(this.label, this.description);

  /// Only closed shapes have an inside and outside.
  bool get needsClosedShape => this == exterior || this == interior || this == pocket;

  /// The colors Shaper Origin reads cut types from (its SVG convention).
  InkPaint? get fill => switch (this) {
        exterior => const InkColor(0, 0, 0),
        interior => const InkColor(1, 1, 1),
        online => null,
        pocket => shaperGray,
        guide => null,
      };

  StrokeStyle? get stroke => switch (this) {
        exterior || interior => const StrokeStyle(width: 1, color: InkColor(0, 0, 0)),
        online => const StrokeStyle(width: 1, color: shaperGray),
        pocket => null,
        guide => const StrokeStyle(width: 1, color: shaperBlue),
      };

  static const shaperGray = InkColor(127 / 255, 127 / 255, 127 / 255);
  static const shaperBlue = InkColor(0, 104 / 255, 1);
}

/// A shape's cut: its type, and (in points) its depth and how far to offset
/// the tool from the line. Null depth means the drawing's default depth.
class CutSpec {
  final CutType type;
  final double? depth;
  final double offset;

  const CutSpec(this.type, {this.depth, this.offset = 0});

  CutSpec copyWith({CutType? type, double? depth, bool defaultDepth = false, double? offset}) => CutSpec(
        type ?? this.type,
        depth: defaultDepth ? null : depth ?? this.depth,
        offset: offset ?? this.offset,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (depth != null) 'depth': depth,
        if (offset != 0) 'offset': offset,
      };

  factory CutSpec.fromJson(Map<String, dynamic> j) => CutSpec(
        CutType.values.asNameMap()[j['type']] ?? CutType.exterior,
        depth: (j['depth'] as num?)?.toDouble(),
        offset: (j['offset'] as num?)?.toDouble() ?? 0,
      );

  /// Shaper's names in its SVG attributes (shaper:cutType).
  String get shaperName => switch (type) {
        CutType.exterior => 'outside',
        CutType.interior => 'inside',
        CutType.online => 'online',
        CutType.pocket => 'pocket',
        CutType.guide => 'guide',
      };

  static CutType? fromShaperName(String? name) => switch (name?.trim().toLowerCase()) {
        'outside' || 'exterior' => CutType.exterior,
        'inside' || 'interior' => CutType.interior,
        'online' || 'on-line' => CutType.online,
        'pocket' => CutType.pocket,
        'guide' => CutType.guide,
        _ => null,
      };

  @override
  bool operator ==(Object other) => other is CutSpec && other.type == type && other.depth == depth && other.offset == offset;

  @override
  int get hashCode => Object.hash(type, depth, offset);
}
