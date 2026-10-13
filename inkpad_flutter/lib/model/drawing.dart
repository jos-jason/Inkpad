import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'cam.dart';
import 'element.dart';
import 'geometry.dart';
import 'style.dart';
import 'units.dart';

export 'cam.dart';
export 'units.dart';

/// Ported from WDLayer.
class InkLayer {
  String name;
  bool visible;
  bool locked;
  double opacity;

  /// Color used to show this layer's selections. Ported from WDLayer.
  InkColor highlightColor;
  final List<InkElement> elements;

  InkLayer({
    required this.name,
    this.visible = true,
    this.locked = false,
    this.opacity = 1,
    this.highlightColor = defaultHighlight,
    List<InkElement>? elements,
  }) : elements = elements ?? [];

  static const defaultHighlight = InkColor(0.04, 0.52, 1);

  /// Highlight colors handed out to new layers in turn.
  static const highlightColors = [
    defaultHighlight,
    InkColor(0.8, 0.2, 0.4),
    InkColor(0.2, 0.7, 0.3),
    InkColor(0.95, 0.55, 0.05),
    InkColor(0.55, 0.3, 0.85),
    InkColor(0.1, 0.7, 0.75),
  ];

  bool get editable => visible && !locked;

  void render(Canvas canvas, Rect clip) {
    if (!visible) return;
    final needsLayer = opacity < 1;
    if (needsLayer) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    for (final e in elements) {
      if (e.paintBounds.overlaps(clip)) e.render(canvas);
    }
    if (needsLayer) canvas.restore();
  }

  String toSvg(SvgWriter w) {
    final attrs = StringBuffer(' id="${_escape(name)}"');
    if (!visible) attrs.write(' visibility="hidden"');
    if (opacity < 1) attrs.write(' opacity="${fmt(opacity)}"');
    return '<g$attrs>${elements.map((e) => e.toSvg(w)).join()}</g>';
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'visible': visible,
        'locked': locked,
        'opacity': opacity,
        'highlight': highlightColor.toJson(),
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  factory InkLayer.fromJson(Map<String, dynamic> j) => InkLayer(
        name: j['name'],
        visible: j['visible'],
        locked: j['locked'],
        opacity: (j['opacity'] as num).toDouble(),
        highlightColor: j['highlight'] == null ? defaultHighlight : InkColor.fromJson(j['highlight']),
        elements: (j['elements'] as List).map((e) => InkElement.fromJson(e)).toList(),
      );
}

/// The document: a sized artboard with ordered layers. Ported from WDDrawing.
class InkDrawing {
  double width;
  double height;
  final List<InkLayer> layers;
  int activeLayerIndex;

  /// Ruler units (a key of [unitSizes]). Ported from WDDrawing's units setting.
  String units;

  /// Ported from WDDrawing's rulersVisible setting.
  bool showRulers;

  /// Snapping and the grid, ported from WDDrawing's settings (all off by
  /// default, with a 36 pt grid, as in Inkpad).
  bool snapToPoints, snapToEdges, snapToGrid, showGrid;
  double gridSpacing;

  /// Make mode: physical dimensions and cutting (for CNC routers such as
  /// the Shaper Origin, laser cutters, …). Shapes stay editable by their
  /// dimensions, and each shape says how it's cut.
  bool makeMode;

  /// Make mode: show where the bit actually cuts.
  bool showCutPreview;

  /// Feeds, speeds and tabs for G-code.
  CamSettings cam;

  /// Inches shown as fractions (1 3/8") to the nearest 1/[inchDenominator];
  /// other units with [decimals] places.
  bool fractionalInches;
  int inchDenominator;
  int decimals;

  /// Material and tool, in points: stock thickness, bit diameter, and the
  /// depth new cuts get.
  double materialThickness, bitDiameter, defaultCutDepth;

  /// Document units (points) per ruler unit.
  static const unitSizes = {'in': 72.0, 'cm': 72 / 2.54, 'mm': 72 / 25.4, 'pt': 1.0, 'px': 1.0};

  InkDrawing({
    this.width = 768,
    this.height = 1024,
    List<InkLayer>? layers,
    this.activeLayerIndex = 0,
    this.units = 'in',
    this.showRulers = true,
    this.snapToPoints = false,
    this.snapToEdges = false,
    this.snapToGrid = false,
    this.showGrid = false,
    this.gridSpacing = 36,
    this.makeMode = false,
    this.showCutPreview = false,
    CamSettings? cam,
    this.fractionalInches = true,
    this.inchDenominator = 32,
    this.decimals = 2,
    this.materialThickness = 18 * 72 / 25.4,
    this.bitDiameter = 6 * 72 / 25.4,
    this.defaultCutDepth = 6 * 72 / 25.4,
  })  : cam = cam ?? CamSettings(),
        layers = layers ?? [InkLayer(name: 'Layer 1')];

  Rect get bounds => Rect.fromLTWH(0, 0, width, height);

  /// How lengths are shown and typed in this drawing.
  LengthFormat get lengths => LengthFormat(
        unit: units == 'px' ? 'pt' : units,
        fractions: fractionalInches,
        denominator: inchDenominator,
        decimals: units == 'in' ? 3 : decimals,
      );

  InkLayer get activeLayer => layers[activeLayerIndex];

  Iterable<InkElement> get allElements => layers.expand((l) => l.elements);

  void render(Canvas canvas, Rect clip) {
    for (final l in layers) {
      l.render(canvas, clip);
    }
  }

  String uniqueLayerName() {
    var i = layers.length + 1;
    while (layers.any((l) => l.name == 'Layer $i')) {
      i++;
    }
    return 'Layer $i';
  }

  void addLayer() {
    layers.insert(
      activeLayerIndex + 1,
      InkLayer(name: uniqueLayerName(), highlightColor: InkLayer.highlightColors[layers.length % InkLayer.highlightColors.length]),
    );
    activeLayerIndex++;
  }

  /// Ported from -[WDDrawing duplicateActiveLayer].
  void duplicateActiveLayer() {
    final copy = InkLayer.fromJson(activeLayer.toJson())..name = '${activeLayer.name} copy';
    layers.insert(activeLayerIndex + 1, copy);
    activeLayerIndex++;
  }

  /// Ported from -[WDDrawing moveLayerAtIndex:toIndex:].
  void moveLayer(int from, int to) {
    final active = activeLayer;
    layers.insert(to, layers.removeAt(from));
    activeLayerIndex = layers.indexOf(active);
  }

  void deleteActiveLayer() {
    if (layers.length <= 1) return;
    layers.removeAt(activeLayerIndex);
    if (activeLayerIndex >= layers.length) activeLayerIndex = layers.length - 1;
  }

  /// SVG export, modelled on -[WDDrawing SVGRepresentation].
  String toSvg() {
    final w = fmt(width), h = fmt(height);
    // Make mode: physical size in the drawing's unit (so cutting tools
    // read it at true size), and Shaper's namespace for cut depths.
    final inches = units == 'in';
    final size = !makeMode
        ? 'width="${w}pt" height="${h}pt"'
        : inches
            ? 'width="${fmt(width / 72)}in" height="${fmt(height / 72)}in"'
            : 'width="${fmt(width * 25.4 / 72)}mm" height="${fmt(height * 25.4 / 72)}mm"';
    final sb = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<!-- Created with Inkpad (Flutter) -->')
      ..writeln('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
          'xmlns:inkpad="http://inkpad.org/ns"${makeMode ? ' xmlns:shaper="http://www.shapertools.com/namespaces/shaper"' : ''} version="1.1" '
          '$size viewBox="0 0 $w $h">');
    final writer = SvgWriter(make: makeMode, defaultDepth: defaultCutDepth, depthUnit: inches ? 'in' : 'mm');
    final body = [for (final l in layers) l.toSvg(writer)];
    if (writer.definitions.isNotEmpty) sb.writeln('<defs>${writer.definitions.join()}</defs>');
    for (final l in body) {
      sb.writeln(l);
    }
    sb.writeln('</svg>');
    return sb.toString();
  }

  /// Every image used in the drawing (including inside groups and masks).
  Set<ImageData> get images => {
        for (final e in allElements)
          for (final d in e.selfAndDescendants)
            if (d is InkImage) d.data,
      };

  /// [includeImages] can be turned off for undo snapshots and change
  /// checks: images never change once placed, and stay registered.
  Map<String, dynamic> toJson({bool includeImages = true}) => {
        'format': 'inkpad-flutter',
        'version': 1,
        'width': width,
        'height': height,
        'activeLayer': activeLayerIndex,
        'units': units,
        'rulers': showRulers,
        'snap': {'points': snapToPoints, 'edges': snapToEdges, 'grid': snapToGrid},
        'grid': {'show': showGrid, 'spacing': gridSpacing},
        if (makeMode) 'make': true,
        if (showCutPreview) 'cutPreview': true,
        'cam': cam.toJson(),
        'lengths': {'fractions': fractionalInches, 'denominator': inchDenominator, 'decimals': decimals},
        'material': {'thickness': materialThickness, 'bit': bitDiameter, 'depth': defaultCutDepth},
        'layers': layers.map((l) => l.toJson()).toList(),
        if (includeImages && images.isNotEmpty)
          'images': {for (final d in images) d.id: base64Encode(d.bytes)},
      };

  factory InkDrawing.fromJson(Map<String, dynamic> j) {
    // Images first, so image elements can find their data.
    for (final encoded in ((j['images'] as Map?) ?? const {}).values) {
      ImageData.register(Uint8List.fromList(base64Decode(encoded as String)));
    }
    return InkDrawing(
      width: (j['width'] as num).toDouble(),
      height: (j['height'] as num).toDouble(),
      activeLayerIndex: j['activeLayer'],
      units: j['units'] as String? ?? 'in',
      showRulers: j['rulers'] as bool? ?? true,
      snapToPoints: j['snap']?['points'] as bool? ?? false,
      snapToEdges: j['snap']?['edges'] as bool? ?? false,
      snapToGrid: j['snap']?['grid'] as bool? ?? false,
      showGrid: j['grid']?['show'] as bool? ?? false,
      gridSpacing: (j['grid']?['spacing'] as num?)?.toDouble() ?? 36,
      makeMode: j['make'] as bool? ?? false,
      showCutPreview: j['cutPreview'] as bool? ?? false,
      cam: j['cam'] == null ? null : CamSettings.fromJson(j['cam']),
      fractionalInches: j['lengths']?['fractions'] as bool? ?? true,
      inchDenominator: j['lengths']?['denominator'] as int? ?? 32,
      decimals: j['lengths']?['decimals'] as int? ?? 2,
      materialThickness: (j['material']?['thickness'] as num?)?.toDouble() ?? 18 * 72 / 25.4,
      bitDiameter: (j['material']?['bit'] as num?)?.toDouble() ?? 6 * 72 / 25.4,
      defaultCutDepth: (j['material']?['depth'] as num?)?.toDouble() ?? 6 * 72 / 25.4,
      layers: (j['layers'] as List).map((l) => InkLayer.fromJson(l)).toList(),
    );
  }

  String encode({bool includeImages = true}) => jsonEncode(toJson(includeImages: includeImages));

  static InkDrawing decode(String s) => InkDrawing.fromJson(jsonDecode(s));
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
