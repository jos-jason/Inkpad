import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/svg/svg_importer.dart';
import 'package:inkpad/tools/tool.dart';
import 'package:inkpad/ui/make/dimension_overlay.dart';
import 'package:inkpad/ui/make/numbers_bar.dart';
import 'package:inkpad/ui/drawing_canvas.dart';

import 'helpers/test_fonts.dart';

double mm(double v) => v * 72 / 25.4;

DrawingController makeController() {
  final c = DrawingController(drawing: InkDrawing(width: mm(600), height: mm(400), units: 'mm'));
  c.setMakeMode(true);
  return c;
}

void drag(DrawingController c, Tool t, Offset a, Offset b) {
  c.tool = t;
  t.begin(c, ToolEvent(a, 1));
  t.move(c, ToolEvent(Offset.lerp(a, b, 0.5)!, 1));
  t.move(c, ToolEvent(b, 1));
  t.end(c, ToolEvent(b, 1));
}

void main() {
  setUpAll(initTestFonts);

  group('live shapes', () {
    test('shapes drawn in Make mode keep their dimensions', () {
      final c = makeController();
      drag(c, ShapeTool(ShapeKind.rectangle), const Offset(10, 10), const Offset(110, 60));
      final r = c.drawing.allElements.single as InkPath;
      expect(r.live!.kind, LiveKind.rectangle);
      expect((r.live!.width, r.live!.height), (100, 50));
      expect(r.cut!.type, CutType.exterior);
      expect(r.fill, CutType.exterior.fill);
      drag(c, ShapeTool(ShapeKind.line), const Offset(0, 100), const Offset(30, 140));
      final line = c.drawing.allElements.last as InkPath;
      expect(line.live!.width, closeTo(50, 1e-9));
      expect(line.cut!.type, CutType.online);
    });

    test('moving, rotating and resizing keep them live; skewing makes a plain path', () {
      final c = makeController();
      final p = InkPath.live(LiveShape.inRect(LiveKind.rectangle, const Rect.fromLTWH(0, 0, 100, 40), cornerRadius: 5));
      c.addElement(p);
      c.select(p);
      c.transformSelection(Affine.translation(20, 30));
      c.transformSelection(Affine.rotationAbout(p.live!.center, math.pi / 2));
      expect(p.live!.angle, closeTo(90, 1e-9));
      expect(p.live!.width, closeTo(100, 1e-9));
      expect(p.live!.height, closeTo(40, 1e-9));
      // Stretching along its own sides changes its dimensions, not its corners.
      c.transformSelection(Affine.scaleAbout(p.live!.center, 1, 2)); // along its width, now vertical
      expect(p.live!.width, closeTo(200, 1e-9));
      expect(p.live!.cornerRadius, 5);
      // Skewing: no longer a rectangle with true dimensions.
      c.transformSelection(Affine.rotationAbout(p.live!.center, 0.3).then(Affine.scaleAbout(p.live!.center, 2, 1)));
      expect(p.live, isNull);
    });

    test('typed sizes, angle and corner radius; JSON keeps it all', () {
      final c = makeController();
      final p = InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(mm(10), mm(10), mm(100), mm(50))));
      c.addElement(p);
      c.select(p);
      c.resizeSelection(width: mm(120));
      expect(c.measure!.width, closeTo(mm(120), 1e-9));
      expect(p.bounds.left, closeTo(mm(10), 1e-9)); // top-left stays put
      c.resizeSelection(height: mm(25), keepProportions: true);
      expect(c.measure!.width, closeTo(mm(60), 1e-9));
      c.setLiveAngle(30);
      expect(p.live!.angle, closeTo(30, 1e-9));
      c.setLiveShape(p, p.live!.copyWith(cornerRadius: mm(3)));
      final back = InkPath.fromJson(p.toJson());
      expect(back.live, p.live);
      expect(back.cut, p.cut);
      c.moveSelectionTo(x: 0, y: 0);
      expect(p.bounds.topLeft.distance, closeTo(0, 1e-9));
      c.undo();
      expect(p.bounds.left, isNot(0));
    });

    test('points of live shapes are not edited directly; Convert to Path frees them', () {
      final c = makeController();
      final p = InkPath.live(LiveShape.inRect(LiveKind.rectangle, const Rect.fromLTWH(0, 0, 100, 100)));
      c.addElement(p);
      c.select(p);
      String? hint;
      c.hint.addListener(() => hint = c.hint.value ?? hint);
      drag(c, DirectSelectTool(), const Offset(0, 0), const Offset(-20, -20));
      expect(p.nodes.first.anchorPoint, Offset.zero);
      expect(hint, contains('Convert to Path'));
      expect(c.canConvertToPaths, isTrue);
      c.convertToPaths();
      expect(p.live, isNull);
      expect(p.nodes.length, 4);
      // Adding a point by hand also makes it a plain path.
      final q = InkPath.live(LiveShape.inRect(LiveKind.ellipse, const Rect.fromLTWH(0, 0, 50, 50)));
      q.insertAnchor(0, 0.5);
      expect(q.live, isNull);
    });
  });

  group('cuts', () {
    test('cut types: open paths only on-line or guide; depth and offset', () {
      final c = makeController();
      final box = InkPath.live(LiveShape.inRect(LiveKind.rectangle, const Rect.fromLTWH(0, 0, 50, 50)));
      final line = InkPath(nodes: [const BezierNode.anchor(Offset.zero), const BezierNode.anchor(Offset(50, 0))]);
      c.addElement(box);
      c.addElement(line);
      c.selectAll();
      c.setCutType(CutType.pocket);
      expect(box.cut!.type, CutType.pocket);
      expect(box.fill, CutType.shaperGray);
      expect(line.cut?.type, isNot(CutType.pocket));
      c.setCutDepth(mm(3));
      expect(box.cut!.depth, closeTo(mm(3), 1e-9));
      c.setCutOffset(mm(0.2));
      expect(line.cut!.offset, closeTo(mm(0.2), 1e-9));
      c.setCutDepth(null);
      expect(box.cut!.depth, isNull);
    });

    test('SVG export is ready for Shaper Origin, and reads back', () {
      final c = makeController();
      c.drawing.defaultCutDepth = mm(6.35);
      final box = InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(0, 0, mm(100), mm(50))));
      c.addElement(box);
      c.select(box);
      c.setCutType(CutType.interior);
      c.addElement(InkText(text: 'Hi', fontFamily: 'Lato', placement: Affine.translation(mm(10), mm(80))));
      final svg = c.drawing.toSvg();
      expect(svg, contains('xmlns:shaper="http://www.shapertools.com/namespaces/shaper"'));
      expect(svg, contains('width="600mm" height="400mm"'));
      expect(svg, contains('shaper:cutDepth="6.35mm"'));
      expect(svg, contains('fill="#ffffff"'));
      expect(svg, isNot(contains('<text'))); // letters as outlines
      final back = importSvg(svg).drawing;
      expect(back.makeMode, isTrue);
      expect(back.units, 'mm');
      expect((back.allElements.first as InkStylable).cut!.type, CutType.interior);

      c.drawing.units = 'in';
      expect(c.drawing.toSvg(), contains('shaper:cutDepth="0.25in"'));
    });

    test('Shaper files from elsewhere: cut types from their colors', () {
      final r = importSvg('<svg xmlns="http://www.w3.org/2000/svg" xmlns:shaper="http://www.shapertools.com/namespaces/shaper" '
          'width="100mm" height="100mm" viewBox="0 0 100 100">'
          '<rect width="10" height="10" fill="#000000" shaper:cutDepth="5mm"/>'
          '<rect x="20" width="10" height="10" fill="#ffffff" stroke="#000"/>'
          '<rect x="40" width="10" height="10" fill="#7f7f7f"/>'
          '<path d="M0 50 L50 50" stroke="#7f7f7f" fill="none"/>'
          '<path d="M0 70 L50 70" stroke="#0068ff" fill="none"/></svg>');
      final cuts = r.drawing.allElements.map((e) => (e as InkStylable).cut!.type).toList();
      expect(cuts, [CutType.exterior, CutType.interior, CutType.pocket, CutType.online, CutType.guide]);
      expect((r.drawing.allElements.first as InkStylable).cut!.depth, closeTo(mm(5), 1e-9));
      expect(r.drawing.makeMode, isTrue);
    });

    test('ordinary SVGs are not treated as cut files', () {
      final r = importSvg('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>');
      expect(r.drawing.makeMode, isFalse);
      expect((r.drawing.allElements.single as InkStylable).cut, isNull);
    });

    test('settings are saved with the drawing', () {
      final d = InkDrawing(units: 'in')
        ..makeMode = true
        ..inchDenominator = 64
        ..bitDiameter = 72 / 8;
      final back = InkDrawing.decode(d.encode());
      expect((back.makeMode, back.inchDenominator, back.bitDiameter), (true, 64, 9));
      expect(back.lengths.format(72 * 1.5), '1 1/2″');
    });
  });

  testWidgets('type sizes in the numbers bar and on the dimension labels', (tester) async {
    final c = makeController();
    final p = InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(mm(10), mm(10), mm(100), mm(50))));
    c.addElement(p);
    c.select(p);
    final view = CanvasView();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Positioned.fill(child: DimensionOverlay(controller: c, view: view, origin: Offset.zero)),
          Align(alignment: Alignment.bottomCenter, child: ListenableBuilder(listenable: c, builder: (_, _) => NumbersBar(controller: c))),
        ]),
      ),
    ));
    expect(find.text('100 mm'), findsWidgets); // width label and field
    expect(find.text('50 mm'), findsWidgets);

    // The numbers bar: width 1 3/8 inches, typed in another unit.
    await tester.enterText(find.widgetWithText(TextField, '100 mm'), '25.4*2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(p.live!.width, closeTo(mm(50.8), 1e-9));

    // The dimension label: tap, type, Enter.
    await tester.tap(find.text('50 mm').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '50 mm').first, '75');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(p.live!.height, closeTo(mm(75), 1e-9));
  });
}
