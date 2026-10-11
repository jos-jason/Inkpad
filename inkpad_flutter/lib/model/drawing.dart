import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'element.dart';
import 'geometry.dart';

/// Ported from WDLayer.
class InkLayer {
  String name;
  bool visible;
  bool locked;
  double opacity;
  final List<InkElement> elements;

  InkLayer({
    required this.name,
    this.visible = true,
    this.locked = false,
    this.opacity = 1,
    List<InkElement>? elements,
  }) : elements = elements ?? [];

  bool get editable => visible && !locked;

  void render(Canvas canvas, Rect clip) {
    if (!visible) return;
    final needsLayer = opacity < 1;
    if (needsLayer) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    for (final e in elements) {
      if (e.styleBounds.overlaps(clip)) e.render(canvas);
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
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  factory InkLayer.fromJson(Map<String, dynamic> j) => InkLayer(
        name: j['name'],
        visible: j['visible'],
        locked: j['locked'],
        opacity: (j['opacity'] as num).toDouble(),
        elements: (j['elements'] as List).map((e) => InkElement.fromJson(e)).toList(),
      );
}

/// The document: a sized artboard with ordered layers. Ported from WDDrawing.
class InkDrawing {
  double width;
  double height;
  final List<InkLayer> layers;
  int activeLayerIndex;

  InkDrawing({
    this.width = 768,
    this.height = 1024,
    List<InkLayer>? layers,
    this.activeLayerIndex = 0,
  }) : layers = layers ?? [InkLayer(name: 'Layer 1')];

  Rect get bounds => Rect.fromLTWH(0, 0, width, height);

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
    layers.insert(activeLayerIndex + 1, InkLayer(name: uniqueLayerName()));
    activeLayerIndex++;
  }

  void deleteActiveLayer() {
    if (layers.length <= 1) return;
    layers.removeAt(activeLayerIndex);
    if (activeLayerIndex >= layers.length) activeLayerIndex = layers.length - 1;
  }

  /// SVG export, modelled on -[WDDrawing SVGRepresentation].
  String toSvg() {
    final w = fmt(width), h = fmt(height);
    final sb = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<!-- Created with Inkpad (Flutter) -->')
      ..writeln('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" '
          'width="${w}pt" height="${h}pt" viewBox="0 0 $w $h">');
    final writer = SvgWriter();
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
