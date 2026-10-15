import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/ui/make/numbers_bar.dart';

double mm(double v) => v * 72 / 25.4;

DrawingController makeController() {
  final c = DrawingController(drawing: InkDrawing(width: mm(1000), height: mm(800), units: 'mm'));
  c.setMakeMode(true);
  return c;
}

InkPath rect(DrawingController c, double x, double y, double w, double h) {
  final p = InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(mm(x), mm(y), mm(w), mm(h))));
  c.addElement(p);
  return p;
}

void main() {
  group('named measurements in sums', () {
    final vars = [
      MakeVariable(name: 'thickness', expression: '12', unit: 'mm'),
      MakeVariable(name: 'width', expression: '600', unit: 'mm'),
      MakeVariable(name: 'inner', expression: 'width - 2*thickness', unit: 'mm'),
      MakeVariable(name: 'shelves', expression: '3', isNumber: true),
      MakeVariable(name: 'loop', expression: 'loop + 1', unit: 'mm'),
    ];
    final lengths = LengthFormat(unit: 'mm', variables: VariableScope(vars).lookup);

    test('names work in sums, with units and implied multiplication', () {
      expect(lengths.parse('thickness'), closeTo(mm(12), 1e-9));
      expect(lengths.parse('inner'), closeTo(mm(576), 1e-9));
      expect(lengths.parse('width/2 - thickness'), closeTo(mm(288), 1e-9));
      expect(lengths.parse('2 thickness + 1in'), closeTo(mm(24 + 25.4), 1e-9));
      expect(lengths.parse('Thickness * shelves'), closeTo(mm(36), 1e-9));
      expect(lengths.parse('(width - thickness) / shelves'), closeTo(mm(196), 1e-9));
    });

    test('lengths keep their size when the drawing is in other units', () {
      final inches = LengthFormat(unit: 'in', variables: VariableScope(vars).lookup);
      expect(inches.parse('thickness'), closeTo(mm(12), 1e-9));
      expect(inches.parse('thickness + 1'), closeTo(mm(12) + 72, 1e-9));
      // Counts stay counts.
      expect(inches.parse('shelves'), closeTo(3 * 72, 1e-9));
    });

    test('unknown names, loops and unit words', () {
      expect(lengths.parse('depth'), isNull);
      expect(lengths.parse('loop'), isNull);
      expect(lengths.parse('2 inner'), closeTo(mm(1152), 1e-9)); // "in" isn't taken from "inner"
      expect(lengths.parse('12mm'), closeTo(mm(12), 1e-9));
      expect(const LengthFormat(unit: 'mm').parse('thickness'), isNull);
      expect(LengthFormat.namesIn('width/2 - 3mm'), {'width'});
      expect(LengthFormat.namesIn('1 3/8" + 2\' 6"'), isEmpty);
      expect(MakeVariable.validName('mm'), isFalse);
      expect(MakeVariable.validName('2x'), isFalse);
      expect(MakeVariable.validName('shelf_depth'), isTrue);
    });

    test('renaming in formulas', () {
      expect(Formula.rename('width/2 - Thickness + thick', 'thickness', 't'), 'width/2 - t + thick');
    });
  });

  group('shapes sized with measurements', () {
    test('follow when a measurement changes, and are saved', () {
      final c = makeController();
      c.setVariables([MakeVariable(name: 'width', expression: '600', unit: 'mm'), MakeVariable(name: 't', expression: '12', unit: 'mm')]);
      final panel = rect(c, 10, 10, 100, 100);
      c.select(panel);
      c.setFormula('w', 'width - 2t', mm(576));
      c.setFormula('x', 't', mm(12));
      expect(panel.live!.width, closeTo(mm(576), 1e-9));
      expect(c.formulaFor('w')!.text, 'width - 2t');

      c.setVariables([MakeVariable(name: 'width', expression: '800', unit: 'mm'), MakeVariable(name: 't', expression: '18', unit: 'mm')]);
      expect(panel.live!.width, closeTo(mm(764), 1e-9));
      expect(panel.bounds.left, closeTo(mm(18), 1e-9));
      expect(panel.live!.height, closeTo(mm(100), 1e-9));

      // Undo puts both the measurement and the shape back.
      c.undo();
      final back = c.drawing.allElements.single as InkPath;
      expect(back.live!.width, closeTo(mm(576), 1e-9));
      expect(c.drawing.variables.first.expression, '600');

      // Saved with the drawing.
      final reloaded = InkDrawing.decode(c.drawing.encode());
      expect(reloaded.variables.map((v) => v.name), ['width', 't']);
      expect(reloaded.allElements.single.formulas['w']!.text, 'width - 2t');
    });

    test('a shape changed by hand forgets its formula', () {
      final c = makeController();
      c.setVariables([MakeVariable(name: 'width', expression: '600', unit: 'mm')]);
      final panel = rect(c, 10, 10, 100, 100);
      c.select(panel);
      c.setFormula('w', 'width', mm(600));
      c.resizeSelection(width: mm(300));
      expect(c.formulaFor('w'), isNull);
      c.setVariables([MakeVariable(name: 'width', expression: '700', unit: 'mm')]);
      expect(panel.live!.width, closeTo(mm(300), 1e-9));
    });

    test('renaming a measurement renames it in formulas', () {
      final c = makeController();
      c.setVariables([MakeVariable(name: 'w', expression: '600', unit: 'mm')]);
      final panel = rect(c, 10, 10, 100, 100);
      c.select(panel);
      c.setFormula('w', 'w/2', mm(300));
      c.setVariables([MakeVariable(name: 'width', expression: '800', unit: 'mm')], renames: {'w': 'width'});
      expect(panel.formulas['w']!.text, 'width/2');
      expect(panel.live!.width, closeTo(mm(400), 1e-9));
    });
  });

  group('pins', () {
    test('a hole follows its panel; moving the hole changes its distance', () {
      final c = makeController();
      final panel = rect(c, 0, 0, 600, 400);
      final hole = rect(c, 37, 180, 20, 40);
      c.selectAll();
      expect(c.pinTarget, same(panel));
      c.pinSelection(horizontal: PinSide.start, vertical: PinSide.center);
      expect(hole.pin!.dx, closeTo(mm(37), 1e-9));
      expect(hole.pin!.dy, closeTo(0, 1e-9));

      // Resize and move the panel: the hole stays 37 mm from the left and centred.
      c.select(panel);
      c.resizeSelection(height: mm(500));
      c.transformSelection(Affine.translation(mm(100), mm(50)));
      expect(hole.bounds.left - panel.bounds.left, closeTo(mm(37), 1e-6));
      expect(hole.bounds.center.dy, closeTo(panel.bounds.center.dy, 1e-6));

      // Moving the hole itself sets a new distance.
      c.select(hole);
      c.transformSelection(Affine.translation(mm(10), 0));
      expect(hole.pin!.dx, closeTo(mm(47), 1e-6));
      c.select(panel);
      c.transformSelection(Affine.translation(mm(-30), 0));
      expect(hole.bounds.left - panel.bounds.left, closeTo(mm(47), 1e-6));
    });

    test('from the far edge, with a distance typed as a formula', () {
      final c = makeController();
      c.setVariables([MakeVariable(name: 'inset', expression: '20', unit: 'mm')]);
      final panel = rect(c, 0, 0, 600, 400);
      final hole = rect(c, 100, 100, 10, 10);
      c.selectAll();
      c.pinSelection(horizontal: PinSide.end, dx: mm(20), dxText: 'inset');
      expect(panel.bounds.right - hole.bounds.right, closeTo(mm(20), 1e-6));
      expect(hole.bounds.top, closeTo(mm(100), 1e-6)); // free top to bottom

      c.select(panel);
      c.resizeSelection(width: mm(500));
      expect(panel.bounds.right - hole.bounds.right, closeTo(mm(20), 1e-6));

      c.setVariables([MakeVariable(name: 'inset', expression: '50', unit: 'mm')]);
      expect(panel.bounds.right - hole.bounds.right, closeTo(mm(50), 1e-6));
    });

    test('pins survive undo and saving; copies are not pinned', () {
      final c = makeController();
      rect(c, 0, 0, 600, 400);
      final hole = rect(c, 37, 180, 20, 40);
      c.selectAll();
      c.pinSelection(horizontal: PinSide.start, vertical: PinSide.start);
      c.select(hole);
      c.duplicateSelection();
      final copy = c.selection.single;
      expect(copy.pin, isNull);

      final reloaded = InkDrawing.decode(c.drawing.encode());
      final c2 = DrawingController(drawing: reloaded);
      final panel2 = reloaded.allElements.first, hole2 = reloaded.allElements.elementAt(1);
      expect(hole2.pin!.target, panel2.id);
      c2.select(panel2);
      c2.transformSelection(Affine.translation(mm(5), mm(5)));
      expect(hole2.bounds.left - panel2.bounds.left, closeTo(mm(37), 1e-6));
    });

    test('deleting the target unpins', () {
      final c = makeController();
      final panel = rect(c, 0, 0, 600, 400);
      final hole = rect(c, 37, 180, 20, 40);
      c.selectAll();
      c.pinSelection(horizontal: PinSide.start);
      c.select(panel);
      c.deleteSelection();
      expect(hole.pin, isNull);
    });
  });

  testWidgets('the numbers bar keeps formulas typed with names', (tester) async {
    final c = makeController();
    c.setVariables([MakeVariable(name: 'width', expression: '600', unit: 'mm')]);
    final panel = rect(c, 10, 10, 100, 100);
    c.select(panel);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: c, builder: (_, _) => NumbersBar(controller: c)))));
    final w = find.widgetWithText(TextField, 'W');
    await tester.tap(w);
    await tester.pump();
    await tester.enterText(w, 'width / 3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(panel.live!.width, closeTo(mm(200), 1e-9));
    expect(c.formulaFor('w')!.text, 'width / 3');
    expect(find.text('ƒ '), findsOneWidget);
  });
}
