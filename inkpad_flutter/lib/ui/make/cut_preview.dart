import 'dart:ui';

import '../../geometry/pathfinder.dart';
import '../../model/drawing.dart';
import '../../model/element.dart';

/// Make mode's cut preview: where the bit actually goes. A band the bit's
/// width follows each cut (outside parts, inside holes, along lines), and
/// pockets show the area the bit can clear — so rounded inside corners and
/// spots too small for the bit show up before cutting.
class CutPreview {
  CutPreview._();

  static final _cache = Expando<(Object, Path?, Path?)>();

  /// The bit's centre path and a pocket's cleared area for [s], cached
  /// until the shape, its cut or the bit changes.
  static (Path?, Path?) _paths(InkStylable s, CutSpec cut, double bit) {
    final key = (s.svgPathData, cut, bit);
    final cached = _cache[s];
    if (cached != null && cached.$1 == key) return (cached.$2, cached.$3);
    final r = bit / 2;
    Path? centre, pocket;
    switch (cut.type) {
      case CutType.exterior:
        centre = Pathfinder.offsetShape(s, r + cut.offset)?.toFlutterPath();
      case CutType.interior:
        centre = Pathfinder.offsetShape(s, -(r + cut.offset))?.toFlutterPath();
      case CutType.online:
        centre = s.toFlutterPath();
      case CutType.pocket:
        pocket = Pathfinder.roundOutsideCorners(s, r)?.toFlutterPath();
        centre = Pathfinder.offsetShape(s, -r)?.toFlutterPath();
      case CutType.guide:
        break;
    }
    _cache[s] = (key, centre, pocket);
    return (centre, pocket);
  }

  /// Draws the preview for every cut shape on visible layers.
  static void paint(Canvas canvas, InkDrawing d) {
    final bit = d.bitDiameter;
    if (bit <= 0) return;
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = bit
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0x55FF7A00);
    final centreLine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0
      ..color = const Color(0xCCFF7A00);
    final cleared = Paint()..color = const Color(0x44FF7A00);
    for (final layer in d.layers) {
      if (!layer.visible) continue;
      for (final e in layer.elements) {
        for (final x in e.selfAndDescendants) {
          if (x is! InkStylable || x is InkGroup) continue;
          final cut = x.cut;
          if (cut == null || cut.type == CutType.guide) continue;
          final (centre, pocket) = _paths(x, cut, bit);
          if (pocket != null) canvas.drawPath(pocket, cleared);
          if (centre != null) {
            canvas.drawPath(centre, band);
            canvas.drawPath(centre, centreLine);
          }
        }
      }
    }
  }
}
