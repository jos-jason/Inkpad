import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/geometry/pathfinder.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/svg/svg_importer.dart';

InkPath square(double x, double y, [double size = 40]) =>
    InkPath.rect(Rect.fromLTWH(x, y, size, size))..fill = const InkColor(1, 0, 0);

/// Renders [e] on white and returns the RGBA bytes of a 100×100 image.
Future<ByteData> pixels(InkElement e) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = const Color(0xFFFFFFFF));
  e.render(canvas);
  final img = await rec.endRecording().toImage(100, 100);
  return (await img.toByteData())!;
}

int red(ByteData d, int x, int y) => d.getUint8((y * 100 + x) * 4);
int green(ByteData d, int x, int y) => d.getUint8((y * 100 + x) * 4 + 1);

void main() {
  group('shadow', () {
    test('direction follows the dial: 315° is down and to the right', () {
      const s = InkShadow(offset: 10, angle: 315);
      expect(s.displacement.dx, closeTo(7.07, 0.01));
      expect(s.displacement.dy, closeTo(7.07, 0.01));
      expect(const InkShadow(offset: 5, angle: 90).displacement.dy, closeTo(-5, 1e-9));
    });

    test('is drawn under the shape, offset, in its color', () async {
      final e = square(20, 20)..shadow = const InkShadow(color: InkColor(0, 0, 0, 1), radius: 0, offset: 20, angle: 315);
      final d = await pixels(e);
      expect((red(d, 30, 30), green(d, 30, 30)), (255, 0)); // the red square on top
      expect((red(d, 70, 70), green(d, 70, 70)), (0, 0)); // black shadow beyond it
      expect(red(d, 10, 70), 255); // untouched
      expect(e.paintBounds.bottom, greaterThan(e.styleBounds.bottom + 10));
    });

    test('blend modes mix with what is beneath', () async {
      final under = square(0, 0, 100)..fill = const InkColor(0, 1, 0);
      final over = square(0, 0, 100)
        ..fill = const InkColor(1, 0, 0)
        ..blendMode = InkBlendMode.screen;
      final d = await pixels(InkGroup([under, over]));
      expect((red(d, 50, 50), green(d, 50, 50)), (255, 255)); // red screen green = yellow
    });

    test('JSON keeps shadow and blend mode', () {
      final e = square(0, 0)
        ..shadow = const InkShadow(color: InkColor(0, 0, 1, 0.5), radius: 6, offset: 9, angle: 45)
        ..blendMode = InkBlendMode.multiply;
      final g = InkGroup([e])..shadow = const InkShadow();
      final copy = InkElement.fromJson(g.toJson()) as InkGroup;
      expect(copy.shadow, const InkShadow());
      expect(copy.elements.single.shadow, e.shadow);
      expect(copy.elements.single.blendMode, InkBlendMode.multiply);
      // Older files without effects still load.
      expect(InkElement.fromJson(square(0, 0).toJson()).shadow, isNull);
    });

    test('SVG export and import round-trip', () {
      const shadow = InkShadow(color: InkColor(0, 0, 1, 0.5), radius: 6, offset: 9, angle: 45);
      final e = square(10, 10)
        ..shadow = shadow
        ..blendMode = InkBlendMode.colorDodge
        ..opacity = 0.5;
      final svg = (InkDrawing()..activeLayer.elements.add(e)).toSvg();
      expect(svg, contains('<feDropShadow'));
      expect(svg, contains('filter="url(#shadow1)"'));
      expect(svg, contains('mix-blend-mode:color-dodge'));
      final back = importSvg(svg).drawing.allElements.single;
      expect(back, isA<InkPath>());
      expect(back.shadow!.offset, closeTo(9, 1e-3));
      expect(back.shadow!.angle, closeTo(45, 1e-3));
      expect(back.shadow!.radius, closeTo(6, 1e-3));
      expect(back.shadow!.color.alpha, closeTo(0.5, 1e-3));
      expect(back.blendMode, InkBlendMode.colorDodge);
      expect(back.opacity, 0.5);
    });

    test('the classic blur + offset filter imports as a shadow', () {
      final r = importSvg('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
          '<filter id="f"><feGaussianBlur in="SourceAlpha" stdDeviation="3"/><feOffset dx="0" dy="4"/>'
          '<feComponentTransfer><feFuncA type="linear" slope="0.3"/></feComponentTransfer>'
          '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
          '<rect width="10" height="10" filter="url(#f)"/>'
          '<rect width="10" height="10" filter="url(#missing)"/></svg>');
      final s = r.drawing.allElements.first.shadow!;
      expect((s.offset, s.angle, s.radius), (4, 270, 6));
      expect(s.color.alpha, closeTo(0.3, 1e-9));
      expect(r.drawing.allElements.last.shadow, isNull);
    });
  });

  group('controller', () {
    test('shadow and blend mode apply to the selection, undoably, and to new shapes', () {
      final c = DrawingController();
      final a = square(0, 0);
      c.addElement(a);
      c.select(a);
      c.setShadow(const InkShadow(offset: 12));
      c.setBlendMode(InkBlendMode.multiply);
      expect(a.shadow!.offset, 12);
      expect(c.shadow!.offset, 12);
      c.undo();
      c.undo();
      expect(c.drawing.allElements.single.shadow, isNull);

      c.selectNone();
      c.setShadow(const InkShadow(offset: 3));
      final p = c.styledPath(square(50, 50));
      expect(p.shadow!.offset, 3);
      // Turning the shadow off keeps its settings for next time.
      c.setShadow(null);
      expect(c.lastShadow.offset, 3);
    });

    test('shape operations keep the shadow', () {
      final c = DrawingController();
      final a = square(0, 0)..shadow = const InkShadow(offset: 7);
      final b = square(20, 20)..shadow = const InkShadow(offset: 7);
      c.addElement(a);
      c.addElement(b);
      c.selectAll();
      c.combineShapes(BooleanOp.unite);
      expect(c.drawing.allElements.single.shadow!.offset, 7);
    });
  });
}
