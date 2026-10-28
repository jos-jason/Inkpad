import 'dart:convert';
import 'dart:typed_data';

import '../model/drawing.dart';
import '../model/element.dart';
import '../svg/svg_importer.dart';

/// What Copy puts on the system clipboard: an SVG of the copied shapes
/// (so other apps can paste them), with Inkpad's own copy of them inside a
/// comment, so pasting them back into any Inkpad drawing — after a
/// restart, or on another device through Universal Clipboard — loses
/// nothing (live shapes, cuts, text, images).
class InkClipboard {
  static const _marker = 'inkpad-clipboard:';

  /// The clipboard text for [elements] from [drawing].
  static String encode(List<InkElement> elements, InkDrawing drawing) {
    final images = {
      for (final e in elements)
        for (final d in e.selfAndDescendants)
          if (d is InkImage) d.data,
    };
    final payload = {
      'elements': [for (final e in elements) e.toJson()],
      if (images.isNotEmpty) 'images': {for (final d in images) d.id: base64Encode(d.bytes)},
    };
    final svg = InkDrawing(
      width: drawing.width,
      height: drawing.height,
      units: drawing.units,
      makeMode: drawing.makeMode,
      defaultCutDepth: drawing.defaultCutDepth,
      layers: [InkLayer(name: 'Copied', elements: [for (final e in elements) e.clone()])],
    ).toSvg();
    final data = base64Encode(utf8.encode(jsonEncode(payload)));
    return svg.replaceFirst('<svg ', '<!--$_marker$data-->\n<svg ');
  }

  /// The shapes in clipboard [text]: Inkpad's own copy when it's there,
  /// otherwise any SVG (from another app); null if it holds neither.
  static List<InkElement>? decode(String text) {
    final at = text.indexOf(_marker);
    if (at >= 0) {
      final end = text.indexOf('-->', at);
      try {
        final payload = jsonDecode(utf8.decode(base64Decode(text.substring(at + _marker.length, end).trim()))) as Map<String, dynamic>;
        for (final encoded in ((payload['images'] as Map?) ?? const {}).values) {
          ImageData.register(Uint8List.fromList(base64Decode(encoded as String)));
        }
        return [for (final j in payload['elements'] as List) InkElement.fromJson(j)];
      } catch (_) {
        // Damaged: fall back to the SVG.
      }
    }
    if (!text.contains('<svg')) return null;
    try {
      final elements = importSvg(text).drawing.allElements.toList();
      return elements.isEmpty ? null : elements;
    } catch (_) {
      return null;
    }
  }
}
