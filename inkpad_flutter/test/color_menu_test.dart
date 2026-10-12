import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/main.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/ui/drawing_canvas.dart';
import 'package:inkpad/ui/panels/color_adjust_panels.dart';

InkPath box(double x, double y, InkPaint? fill) => InkPath.rect(Rect.fromLTWH(x, y, 10, 10))..fill = fill;

Matcher color(double r, double g, double b) => isA<InkColor>()
    .having((c) => c.red, 'red', closeTo(r, 1e-6))
    .having((c) => c.green, 'green', closeTo(g, 1e-6))
    .having((c) => c.blue, 'blue', closeTo(b, 1e-6));

DrawingController withSelection(List<InkElement> elements) {
  final c = DrawingController();
  for (final e in elements) {
    c.addElement(e);
  }
  c.selectAll();
  return c;
}

void main() {
  group('color math (as WDColor)', () {
    test('hue shift wraps; saturation and brightness scale', () {
      expect(const InkColor(1, 0, 0).adjustHsb(120, 0, 0), color(0, 1, 0));
      expect(const InkColor(1, 0, 0).adjustHsb(-120, 0, 0), color(0, 0, 1));
      expect(const InkColor(1, 0.5, 0.5).adjustHsb(0, -1, 0), color(1, 1, 1));
      expect(const InkColor(1, 0, 0).adjustHsb(0, 0, -0.5), color(0.5, 0, 0));
      expect(const InkColor(0.2, 0.4, 0.6, 0.3).adjustHsb(0, 0, 0).alpha, 0.3);
    });

    test('balance shifts channels; invert flips them', () {
      expect(const InkColor(0.5, 0.5, 0.5).balance(0.25, -0.75, 0), color(0.75, 0, 0.5));
      expect(const InkColor(0.2, 0.4, 1, 0.5).inverted, color(0.8, 0.6, 0));
      expect(const InkColor(0.2, 0.4, 1, 0.5).inverted.alpha, 0.5);
    });
  });

  group('blending', () {
    test('back to front blends between the bottom and top colors', () {
      final shapes = [
        box(0, 0, const InkColor(1, 0, 0)),
        box(50, 0, const InkColor(0, 1, 0)),
        box(10, 0, null), // no fill: not blended
        box(20, 0, const InkColor(0, 0, 0)),
        box(30, 0, const InkColor(0, 0, 1)),
      ];
      final c = withSelection(shapes);
      expect(c.canBlendColors(ColorBlend.backToFront), isTrue);
      c.blendColors(ColorBlend.backToFront);
      expect(shapes[1].fill, color(2 / 3, 0, 1 / 3));
      expect(shapes[2].fill, isNull);
      expect(shapes[3].fill, color(1 / 3, 0, 2 / 3));
      c.undo();
      expect((c.drawing.allElements.elementAt(1) as InkPath).fill, color(0, 1, 0));
    });

    test('horizontally goes by position, left to right', () {
      final shapes = [
        box(100, 0, const InkColor(0, 0, 1)), // right end
        box(25, 50, const InkColor(0.5, 0.5, 0.5)),
        box(0, 0, const InkColor(1, 0, 0)), // left end
      ];
      final c = withSelection(shapes);
      c.blendColors(ColorBlend.horizontally);
      expect(shapes[1].fill, color(0.75, 0, 0.25));
      expect(c.canBlendColors(ColorBlend.vertically), isTrue);
    });

    test('needs three shapes with solid end colors; reaches into groups', () {
      expect(withSelection([box(0, 0, InkColor.black), box(10, 0, InkColor.black)]).canBlendColors(ColorBlend.backToFront), isFalse);
      final grad = InkGradient.between(InkColor.black, const InkColor(1, 1, 1));
      expect(
        withSelection([box(0, 0, grad), box(10, 0, InkColor.black), box(20, 0, InkColor.black)]).canBlendColors(ColorBlend.backToFront),
        isFalse,
      );
      final inner = box(10, 0, InkColor.black);
      final c = withSelection([box(0, 0, InkColor.black), InkGroup([inner, box(15, 0, InkColor.black)]), box(30, 0, const InkColor(1, 1, 1))]);
      c.blendColors(ColorBlend.backToFront);
      expect(inner.fill, color(1 / 3, 1 / 3, 1 / 3));
    });
  });

  group('adjusting', () {
    test('invert and desaturate reach fills, gradients, strokes and shadows, as one undo step', () {
      final a = box(0, 0, const InkColor(1, 0, 0))
        ..stroke = const StrokeStyle(width: 2, color: InkColor(0, 1, 0))
        ..shadow = const InkShadow(color: InkColor(0, 0, 0, 0.5));
      final g = box(20, 0, InkGradient.between(const InkColor(1, 0, 0), const InkColor(0, 0, 1)));
      final c = withSelection([InkGroup([a, g])]);
      expect(c.canAdjustColors, isTrue);
      c.invertColors();
      expect(a.fill, color(0, 1, 1));
      expect(a.stroke!.color, color(1, 0, 1));
      expect(a.shadow!.color, color(1, 1, 1));
      expect(a.shadow!.color.alpha, 0.5);
      expect((g.fill as InkGradient).stops.first.color, color(0, 1, 1));
      c.undo();
      final restored = (c.drawing.allElements.single as InkGroup).elements.first as InkPath;
      expect(restored.fill, color(1, 0, 0));
      expect(c.canUndo, isFalse);

      c.selectAll();
      c.desaturate();
      final r = (c.drawing.allElements.single as InkGroup).elements.first as InkPath;
      expect(r.fill, color(1, 1, 1)); // full brightness, no saturation
    });

    test('nothing colorable means nothing to adjust', () {
      expect(withSelection([box(0, 0, null)]).canAdjustColors, isFalse);
      expect(DrawingController().canAdjustColors, isFalse);
    });

    test('live adjustment previews from the originals; cancel restores without an undo step', () {
      final a = box(0, 0, const InkColor(1, 0, 0));
      final c = withSelection([a]);
      final undoBefore = c.canUndo;
      c.beginColorAdjustment();
      c.previewColorAdjustment((x) => x.adjustHsb(60, 0, 0));
      c.previewColorAdjustment((x) => x.adjustHsb(120, 0, 0)); // not cumulative
      expect(a.fill, color(0, 1, 0));
      c.endColorAdjustment(cancel: true);
      expect(a.fill, color(1, 0, 0));
      expect(c.canUndo, undoBefore);

      c.beginColorAdjustment();
      c.endColorAdjustment(); // no change: no undo step either
      expect(c.canUndo, undoBefore);

      c.beginColorAdjustment();
      c.previewColorAdjustment((x) => x.balance(0, 0, 1));
      c.endColorAdjustment();
      expect(a.fill, color(1, 0, 1));
      c.undo();
      expect((c.drawing.allElements.single as InkPath).fill, color(1, 0, 0));
    });
  });

  testWidgets('the color wheel menu opens Hue and Saturation; Cancel and Done', (tester) async {
    final lib = LibraryController(MemoryDrawingStore());
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rectangle (R)'));
    await tester.pump();
    await tester.dragFrom(tester.getCenter(find.byType(DrawingCanvas)), const Offset(100, 60));
    await tester.pumpAndSettle();
    final c = tester.state<DrawingCanvasState>(find.byType(DrawingCanvas)).widget.controller;
    final rect = c.drawing.allElements.single as InkPath;
    rect.fill = const InkColor(1, 0, 0);
    c.select(rect);
    await tester.pump();

    Future<void> openHue() async {
      await tester.tap(find.byTooltip('Color'));
      await tester.pumpAndSettle();
      expect(find.text('Blend Back to Front'), findsOneWidget);
      await tester.tap(find.text('Hue and Saturation…'));
      await tester.pumpAndSettle();
      expect(find.text('Hue'), findsOneWidget);
      // Nudge the hue up 3°: previewed on the drawing straight away.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.descendant(of: find.byType(HueSaturationPanel), matching: find.byIcon(Icons.add)).first);
        await tester.pump();
      }
      expect(rect.fill, isNot(color(1, 0, 0)));
    }

    await openHue();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(rect.fill, color(1, 0, 0));
    expect(find.text('Hue'), findsNothing);

    await openHue();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect((rect.fill as InkColor).hue, closeTo(3, 0.01));
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    expect((c.drawing.allElements.single as InkPath).fill, color(1, 0, 0));
  });
}
