import 'dart:math' as math;
import 'dart:ui';

import 'geometry.dart';
import 'style.dart';

/// A drop shadow. Ported from WDShadow: a color, a blur radius, and an
/// offset at an angle.
class InkShadow {
  final InkColor color;

  /// Blur radius in points.
  final double radius;

  /// Distance from the shape in points.
  final double offset;

  /// Direction in degrees, counterclockwise from the right, as on the
  /// panel's dial (315 = down and to the right).
  final double angle;

  const InkShadow({
    this.color = const InkColor(0, 0, 0, 1 / 3),
    this.radius = 4,
    this.offset = 4,
    this.angle = 315,
  });

  /// Where the shadow sits relative to the shape, in document space (y down).
  Offset get displacement {
    final a = angle * math.pi / 180;
    return Offset(math.cos(a) * offset, -math.sin(a) * offset);
  }

  /// Gaussian blur sigma for [radius] (CoreGraphics' blur is about twice
  /// the standard deviation).
  double get sigma => radius / 2;

  /// How far the shadow can reach beyond the shape.
  double get extent => offset + radius * 1.5;

  InkShadow copyWith({InkColor? color, double? radius, double? offset, double? angle}) => InkShadow(
        color: color ?? this.color,
        radius: radius ?? this.radius,
        offset: offset ?? this.offset,
        angle: angle ?? this.angle,
      );

  /// Paints [content] as a blurred, offset silhouette in the shadow color.
  void paint(Canvas canvas, Rect bounds, void Function() content) {
    final d = displacement;
    final layerBounds = bounds.shift(d).inflate(radius * 1.5 + 1);
    canvas.saveLayer(
      layerBounds,
      Paint()
        ..colorFilter = ColorFilter.mode(color.toColor(), BlendMode.srcIn)
        ..imageFilter = sigma > 0 ? ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal) : null,
    );
    canvas.translate(d.dx, d.dy);
    content();
    canvas.restore();
  }

  /// An SVG `<filter>` producing this shadow under its source.
  String svgFilter(String id) {
    final d = displacement;
    return '<filter id="$id" x="-50%" y="-50%" width="200%" height="200%" color-interpolation-filters="sRGB">'
        '<feDropShadow dx="${fmt(d.dx)}" dy="${fmt(d.dy)}" stdDeviation="${fmt(sigma)}" '
        'flood-color="${color.hexValue}" flood-opacity="${fmt(color.alpha)}"/></filter>';
  }

  Map<String, dynamic> toJson() => {'color': color.toJson(), 'radius': radius, 'offset': offset, 'angle': angle};

  factory InkShadow.fromJson(Map<String, dynamic> j) => InkShadow(
        color: InkColor.fromJson(j['color']),
        radius: (j['radius'] as num).toDouble(),
        offset: (j['offset'] as num).toDouble(),
        angle: (j['angle'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is InkShadow && other.color == color && other.radius == radius && other.offset == offset && other.angle == angle;

  @override
  int get hashCode => Object.hash(color, radius, offset, angle);
}

/// How an element mixes with what's beneath it. Inkpad's blend modes
/// (WDBlendModes), in its menu order.
enum InkBlendMode {
  normal('Normal', BlendMode.srcOver, 'normal'),
  darken('Darken', BlendMode.darken, 'darken'),
  multiply('Multiply', BlendMode.multiply, 'multiply'),
  colorBurn('Color Burn', BlendMode.colorBurn, 'color-burn'),
  lighten('Lighten', BlendMode.lighten, 'lighten'),
  screen('Screen', BlendMode.screen, 'screen'),
  colorDodge('Color Dodge', BlendMode.colorDodge, 'color-dodge'),
  overlay('Overlay', BlendMode.overlay, 'overlay'),
  softLight('Soft Light', BlendMode.softLight, 'soft-light'),
  hardLight('Hard Light', BlendMode.hardLight, 'hard-light'),
  difference('Difference', BlendMode.difference, 'difference'),
  exclusion('Exclusion', BlendMode.exclusion, 'exclusion'),
  hue('Hue', BlendMode.hue, 'hue'),
  saturation('Saturation', BlendMode.saturation, 'saturation'),
  color('Color', BlendMode.color, 'color'),
  luminosity('Luminosity', BlendMode.luminosity, 'luminosity');

  final String label;
  final BlendMode flutter;

  /// The CSS `mix-blend-mode` value.
  final String css;

  const InkBlendMode(this.label, this.flutter, this.css);

  static InkBlendMode? fromCss(String? value) => values.where((m) => m.css == value?.trim()).firstOrNull;
}
