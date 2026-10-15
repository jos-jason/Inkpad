import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect;

import 'geometry.dart';
import 'style.dart';

enum GradientType { linear, radial }

/// What a gradient does beyond its ends (SVG spreadMethod).
enum SpreadMethod { pad, reflect, repeat }

/// Ported from WDGradientStop.
class GradientStop {
  /// Position along the gradient, 0..1.
  final double offset;
  final InkColor color;

  const GradientStop(this.offset, this.color);

  Map<String, dynamic> toJson() => {'offset': offset, 'color': color.toJson()};

  factory GradientStop.fromJson(Map<String, dynamic> j) =>
      GradientStop((j['offset'] as num).toDouble(), InkColor.fromJson(j['color']));

  @override
  bool operator ==(Object other) => other is GradientStop && offset == other.offset && color == other.color;

  @override
  int get hashCode => Object.hash(offset, color);
}

/// Where a gradient sits. Ported from WDFillTransform.
///
/// [start] and [end] are in gradient space, which [transform] maps into
/// document space (this is how skewed or elliptical gradients from SVG files
/// are represented). Linear: the gradient runs from start to end.
/// Radial: start is the center and the radius reaches end.
class GradientGeometry {
  final Offset start, end;

  /// Radial only: the focal point, if different from the center.
  final Offset? focal;
  final Affine transform;

  const GradientGeometry(this.start, this.end, {this.focal, this.transform = Affine.identity});

  /// Inkpad's default: horizontally across the middle of [r]
  /// (from the center for radial gradients).
  factory GradientGeometry.fit(Rect r, GradientType type) => GradientGeometry(
        Offset(type == GradientType.radial ? r.center.dx : r.left, r.center.dy),
        Offset(r.right, r.center.dy),
      );

  Offset get documentStart => transform.apply(start);
  Offset get documentEnd => transform.apply(end);

  /// Moves an end point to a document-space position.
  GradientGeometry withDocumentStart(Offset doc) {
    final p = transform.inverted().apply(doc);
    final f = focal;
    return GradientGeometry(p, end, focal: f == null ? null : f + (p - start), transform: transform);
  }

  GradientGeometry withDocumentEnd(Offset doc) =>
      GradientGeometry(start, transform.inverted().apply(doc), focal: focal, transform: transform);

  GradientGeometry transformed(Affine t) =>
      GradientGeometry(start, end, focal: focal, transform: transform.then(t));

  Map<String, dynamic> toJson() => {
        'start': offsetToJson(start),
        'end': offsetToJson(end),
        if (focal != null) 'focal': offsetToJson(focal!),
        if (!transform.isIdentity) 'transform': transform.toJson(),
      };

  factory GradientGeometry.fromJson(Map<String, dynamic> j) => GradientGeometry(
        offsetFromJson(j['start']),
        offsetFromJson(j['end']),
        focal: j['focal'] == null ? null : offsetFromJson(j['focal']),
        transform: j['transform'] == null ? Affine.identity : Affine.fromJson(j['transform']),
      );

  @override
  bool operator ==(Object other) =>
      other is GradientGeometry &&
      start == other.start &&
      end == other.end &&
      focal == other.focal &&
      transform == other.transform;

  @override
  int get hashCode => Object.hash(start, end, focal, transform);
}

/// A linear or radial gradient fill. Ported from WDGradient.
class InkGradient implements InkPaint {
  final GradientType type;

  /// Sorted by offset; at least one stop.
  final List<GradientStop> stops;
  final SpreadMethod spread;

  /// Null means "fit to the shape" (Inkpad's default fill transform), so a
  /// gradient chosen in the inspector suits whatever shape it is applied to.
  final GradientGeometry? geometry;

  const InkGradient({
    this.type = GradientType.linear,
    required this.stops,
    this.spread = SpreadMethod.pad,
    this.geometry,
  });

  /// Ported from +[WDGradient gradientWithStart:andEnd:].
  factory InkGradient.between(InkColor start, InkColor end, {GradientType type = GradientType.linear}) =>
      InkGradient(type: type, stops: [GradientStop(0, start), GradientStop(1, end)]);

  /// The geometry to use for a shape with [bounds].
  GradientGeometry fitted(Rect bounds) => geometry ?? GradientGeometry.fit(bounds, type);

  InkGradient copyWith({
    GradientType? type,
    List<GradientStop>? stops,
    SpreadMethod? spread,
    GradientGeometry? geometry,
    bool clearGeometry = false,
  }) =>
      InkGradient(
        type: type ?? this.type,
        stops: stops ?? this.stops,
        spread: spread ?? this.spread,
        geometry: clearGeometry ? null : geometry ?? this.geometry,
      );

  InkGradient withStopColor(int index, InkColor color) =>
      copyWith(stops: [for (final (i, s) in stops.indexed) i == index ? GradientStop(s.offset, color) : s]);

  /// Ported from -[WDGradient gradientByReversing].
  InkGradient reversed() =>
      copyWith(stops: [for (final s in stops.reversed) GradientStop(1 - s.offset, s.color)]);

  /// Color at [t] (0..1) along the gradient. Ported from -[WDGradient colorAtRatio:].
  InkColor colorAt(double t) {
    if (t <= stops.first.offset) return stops.first.color;
    for (var i = 1; i < stops.length; i++) {
      final a = stops[i - 1], b = stops[i];
      if (t <= b.offset) {
        final span = b.offset - a.offset;
        return span <= 0 ? b.color : a.color.lerp(b.color, (t - a.offset) / span);
      }
    }
    return stops.last.color;
  }

  @override
  InkColor get representativeColor => colorAt(0.5);

  /// A shader for a shape with [bounds], with [opacity] applied to every stop.
  /// Null if the gradient is degenerate (zero length), in which case SVG
  /// renders the last stop's color.
  ui.Shader? shader(Rect bounds, double opacity) {
    final g = fitted(bounds);
    if (g.start == g.end) return null;
    final colors = [for (final s in stops) s.color.toColor(opacity)];
    final offsets = [for (final s in stops) s.offset.clamp(0.0, 1.0)];
    final tile = switch (spread) {
      SpreadMethod.pad => ui.TileMode.clamp,
      SpreadMethod.reflect => ui.TileMode.mirror,
      SpreadMethod.repeat => ui.TileMode.repeated,
    };
    final matrix = g.transform.isIdentity ? null : Float64List.fromList(g.transform.toMatrix4());
    if (type == GradientType.linear) {
      return ui.Gradient.linear(g.start, g.end, colors, offsets, tile, matrix);
    }
    final radius = (g.end - g.start).distance;
    final focal = g.focal;
    return ui.Gradient.radial(
      g.start,
      radius,
      colors,
      offsets,
      tile,
      matrix,
      focal != null && focal != g.start ? focal : null,
    );
  }

  /// The `<linearGradient>`/`<radialGradient>` definition for a shape with [bounds].
  String svgDefinition(String id, Rect bounds) {
    final g = fitted(bounds);
    final sb = StringBuffer();
    final tag = type == GradientType.linear ? 'linearGradient' : 'radialGradient';
    sb.write('<$tag id="$id" gradientUnits="userSpaceOnUse"');
    if (type == GradientType.linear) {
      sb.write(' x1="${fmt(g.start.dx)}" y1="${fmt(g.start.dy)}" x2="${fmt(g.end.dx)}" y2="${fmt(g.end.dy)}"');
    } else {
      sb.write(' cx="${fmt(g.start.dx)}" cy="${fmt(g.start.dy)}" r="${fmt((g.end - g.start).distance)}"');
      final f = g.focal;
      if (f != null && f != g.start) sb.write(' fx="${fmt(f.dx)}" fy="${fmt(f.dy)}"');
    }
    if (!g.transform.isIdentity) {
      final t = g.transform;
      sb.write(' gradientTransform="matrix(${[t.a, t.b, t.c, t.d, t.tx, t.ty].map(fmt).join(' ')})"');
    }
    if (spread != SpreadMethod.pad) sb.write(' spreadMethod="${spread.name}"');
    sb.write('>');
    for (final s in stops) {
      sb.write('<stop offset="${fmt(s.offset)}" stop-color="${s.color.hexValue}"');
      if (s.color.alpha != 1) sb.write(' stop-opacity="${fmt(s.color.alpha)}"');
      sb.write('/>');
    }
    sb.write('</$tag>');
    return sb.toString();
  }

  @override
  Map<String, dynamic> toJson() => {
        'gradient': type.name,
        'stops': stops.map((s) => s.toJson()).toList(),
        if (spread != SpreadMethod.pad) 'spread': spread.name,
        if (geometry != null) 'geometry': geometry!.toJson(),
      };

  factory InkGradient.fromJson(Map<String, dynamic> j) => InkGradient(
        type: GradientType.values.byName(j['gradient'] as String? ?? 'linear'),
        stops: (j['stops'] as List).map((s) => GradientStop.fromJson(s)).toList(),
        spread: SpreadMethod.values.byName(j['spread'] as String? ?? 'pad'),
        geometry: j['geometry'] == null ? null : GradientGeometry.fromJson(j['geometry']),
      );

  @override
  bool operator ==(Object other) =>
      other is InkGradient &&
      type == other.type &&
      spread == other.spread &&
      geometry == other.geometry &&
      _listEquals(stops, other.stops);

  @override
  int get hashCode => Object.hash(type, spread, geometry, Object.hashAll(stops));
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

