import 'dart:ui';

import 'geometry.dart';
import 'gradient.dart';

export 'gradient.dart';

/// Something a shape can be filled with: a solid [InkColor] or an
/// [InkGradient]. Ported from Inkpad's WDPathPainter protocol.
abstract interface class InkPaint {
  Map<String, dynamic> toJson();

  /// A single color that best represents this paint (for swatches).
  InkColor get representativeColor;

  static InkPaint fromJson(Map<String, dynamic> j) =>
      j.containsKey('stops') ? InkGradient.fromJson(j) : InkColor.fromJson(j);
}

/// RGBA color with components in 0..1. Ported (in part) from WDColor.
class InkColor implements InkPaint {
  final double red, green, blue, alpha;

  const InkColor(this.red, this.green, this.blue, [this.alpha = 1]);

  static const black = InkColor(0, 0, 0);
  static const white = InkColor(1, 1, 1);

  factory InkColor.fromHex(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    final v = int.parse(h.substring(0, 6), radix: 16);
    return InkColor(
      ((v >> 16) & 0xff) / 255,
      ((v >> 8) & 0xff) / 255,
      (v & 0xff) / 255,
    );
  }

  String get hexValue {
    String c(double v) => (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${c(red)}${c(green)}${c(blue)}';
  }

  Color toColor([double extraOpacity = 1]) => Color.from(
        alpha: (alpha * extraOpacity).clamp(0.0, 1.0),
        red: red,
        green: green,
        blue: blue,
      );

  InkColor withAlpha(double a) => InkColor(red, green, blue, a);

  @override
  InkColor get representativeColor => this;

  /// From hue (degrees), saturation and brightness (0..1), as in Inkpad's
  /// HSB color pickers.
  factory InkColor.hsb(double hue, double saturation, double brightness, [double alpha = 1]) {
    final h = (hue % 360) / 60, c = brightness * saturation;
    final x = c * (1 - ((h % 2) - 1).abs()), m = brightness - c;
    final (r, g, b) = switch (h.floor()) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    return InkColor(r + m, g + m, b + m, alpha);
  }

  double get brightness => [red, green, blue].reduce((a, b) => a > b ? a : b);

  double get saturation {
    final max = brightness, min = [red, green, blue].reduce((a, b) => a < b ? a : b);
    return max == 0 ? 0 : (max - min) / max;
  }

  /// Hue in degrees (0 for grays).
  double get hue {
    final max = brightness, min = [red, green, blue].reduce((a, b) => a < b ? a : b);
    final d = max - min;
    if (d == 0) return 0;
    final h = max == red
        ? ((green - blue) / d) % 6
        : max == green
            ? (blue - red) / d + 2
            : (red - green) / d + 4;
    return (h * 60 + 360) % 360;
  }

  /// Shifts hue by [hueShift] degrees and scales saturation and brightness
  /// by 1 + shift (shifts are -1..1). Ported from -[WDColor adjustHue:...].
  InkColor adjustHsb(double hueShift, double saturationShift, double brightnessShift) => InkColor.hsb(
        hue + hueShift,
        (saturation * (1 + saturationShift)).clamp(0.0, 1.0),
        (brightness * (1 + brightnessShift)).clamp(0.0, 1.0),
        alpha,
      );

  /// Adds the shifts (-1..1) to each channel. Ported from
  /// -[WDColor colorBalanceRed:green:blue:].
  InkColor balance(double redShift, double greenShift, double blueShift) => InkColor(
        (red + redShift).clamp(0.0, 1.0),
        (green + greenShift).clamp(0.0, 1.0),
        (blue + blueShift).clamp(0.0, 1.0),
        alpha,
      );

  InkColor get inverted => InkColor(1 - red, 1 - green, 1 - blue, alpha);

  /// Linear interpolation towards [other].
  InkColor lerp(InkColor other, double t) => InkColor(
        red + (other.red - red) * t,
        green + (other.green - green) * t,
        blue + (other.blue - blue) * t,
        alpha + (other.alpha - alpha) * t,
      );

  @override
  Map<String, dynamic> toJson() => {'r': red, 'g': green, 'b': blue, 'a': alpha};

  factory InkColor.fromJson(Map<String, dynamic> j) => InkColor(
        (j['r'] as num).toDouble(),
        (j['g'] as num).toDouble(),
        (j['b'] as num).toDouble(),
        (j['a'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is InkColor &&
      red == other.red &&
      green == other.green &&
      blue == other.blue &&
      alpha == other.alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);
}

enum LineCap { butt, round, square }

enum LineJoin { miter, round, bevel }

/// Ported from WDStrokeStyle (arrowheads not yet supported).
class StrokeStyle {
  final double width;
  final LineCap cap;
  final LineJoin join;
  final InkColor color;
  final List<double> dashPattern;

  const StrokeStyle({
    this.width = 1,
    this.cap = LineCap.round,
    this.join = LineJoin.round,
    this.color = InkColor.black,
    this.dashPattern = const [],
  });

  bool get willRender => width > 0 && color.alpha > 0;

  StrokeStyle copyWith({double? width, InkColor? color, LineCap? cap, LineJoin? join, List<double>? dashPattern}) =>
      StrokeStyle(
        width: width ?? this.width,
        cap: cap ?? this.cap,
        join: join ?? this.join,
        color: color ?? this.color,
        dashPattern: dashPattern ?? this.dashPattern,
      );

  StrokeCap get flutterCap => switch (cap) {
        LineCap.butt => StrokeCap.butt,
        LineCap.round => StrokeCap.round,
        LineCap.square => StrokeCap.square,
      };

  StrokeJoin get flutterJoin => switch (join) {
        LineJoin.miter => StrokeJoin.miter,
        LineJoin.round => StrokeJoin.round,
        LineJoin.bevel => StrokeJoin.bevel,
      };

  Map<String, String> svgAttributes() => {
        'stroke': color.hexValue,
        if (color.alpha != 1) 'stroke-opacity': fmt(color.alpha),
        'stroke-width': fmt(width),
        'stroke-linecap': cap.name,
        'stroke-linejoin': join.name,
        if (dashPattern.isNotEmpty) 'stroke-dasharray': dashPattern.map(fmt).join(','),
      };

  Map<String, dynamic> toJson() => {
        'width': width,
        'cap': cap.name,
        'join': join.name,
        'color': color.toJson(),
        'dash': dashPattern,
      };

  factory StrokeStyle.fromJson(Map<String, dynamic> j) => StrokeStyle(
        width: (j['width'] as num).toDouble(),
        cap: LineCap.values.byName(j['cap']),
        join: LineJoin.values.byName(j['join']),
        color: InkColor.fromJson(j['color']),
        dashPattern: (j['dash'] as List).cast<num>().map((n) => n.toDouble()).toList(),
      );
}
