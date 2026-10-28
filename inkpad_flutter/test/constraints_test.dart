import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/tools/tool.dart';
import 'package:inkpad/ui/make/constraint_bar.dart';
import 'package:inkpad/ui/make/dimension_dialog.dart';

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

void click(DrawingController c, Tool t, Offset at, {int count = 1}) {
  c.tool = t;
  final e = ToolEvent(at, 1, count: count);
  t.begin(c, e);
  t.end(c, e);
}

void main() {
  test('picking with the tool makes constraints; dragging keeps them', () {
    final c = makeController();
    final a = rect(c, 0, 0, 100, 50), b = rect(c, 130, 20, 40, 40);
    final tool = ConstraintTool();
    // Join b's top-left corner to a's top-right corner.
    tool.setMode(c, SketchMode.coincident);
    click(c, tool, a.live!.corners[1]);
    click(c, tool, b.live!.corners[0]);
    expect(c.drawing.constraints.single.type, ConstraintType.coincident);
    // The first picked moves to the last.
    expect(a.live!.corners[1].dx, closeTo(mm(130), 1e-3));
    expect(b.live!.corners[0].dx, closeTo(mm(130), 1e-3));

    // Dragging b brings a along; a stays its size.
    c.select(b);
    c.transformSelection(Affine.translation(mm(50), mm(10)));
    expect((a.live!.corners[1] - b.live!.corners[0]).distance, lessThan(1e-3));
    expect(b.live!.corners[0].dx, closeTo(mm(180), 1e-3));

    // Saved with the drawing.
    final reloaded = InkDrawing.decode(c.drawing.encode());
    expect(reloaded.constraints.single.refs.length, 2);
  });

  test('dimensions drive sizes, follow measurements, and conflicts are refused', () {
    final c = makeController();
    c.setVariables([MakeVariable(name: 'width', expression: '600', unit: 'mm')]);
    final a = rect(c, 10, 10, 100, 50);
    final top = GeoRef(a.ensureId, GeoKind.line, 0), bottom = GeoRef(a.id!, GeoKind.line, 2);
    expect(c.constrain(ConstraintType.distance, [top], value: mm(600), formulaText: 'width'), isNull);
    expect(a.live!.width, closeTo(mm(600), 1e-3));

    c.setVariables([MakeVariable(name: 'width', expression: '450', unit: 'mm')]);
    expect(a.live!.width, closeTo(mm(450), 1e-3));

    // The bottom is the same length as the top: as a dimension it would
    // over-constrain, so it's kept as a reference.
    expect(c.constrain(ConstraintType.distance, [bottom], value: mm(300)), isNull);
    final ref = c.drawing.constraints.last;
    expect(ref.reference, isTrue);
    expect(ref.value, closeTo(mm(450), 1e-3));

    // Horizontal twice is already settled.
    expect(c.constrain(ConstraintType.horizontal, [top]), isNull);
    expect(c.constrain(ConstraintType.horizontal, [bottom]), isNotNull);
    expect(c.drawing.constraints.length, 3);

    // A fixed corner and a fixed far corner can't both hold a new width.
    final dim = c.drawing.constraints.first;
    expect(c.setConstraintValue(dim, mm(500)), isTrue);
    expect(a.live!.width, closeTo(mm(500), 1e-3));
  });

  test('resizing a dimensioned shape by hand snaps back; deleting the shape removes its constraints', () {
    final c = makeController();
    final a = rect(c, 10, 10, 100, 50);
    c.constrain(ConstraintType.distance, [GeoRef(a.ensureId, GeoKind.line, 0)], value: mm(100));
    c.select(a);
    c.resizeSelection(width: mm(200));
    expect(a.live!.width, closeTo(mm(100), 1e-3));
    c.deleteSelection();
    expect(c.drawing.constraints, isEmpty);
  });

  test('degrees of freedom', () {
    final c = makeController();
    final a = rect(c, 10, 10, 100, 50);
    final id = a.ensureId;
    c.constrain(ConstraintType.fix, [GeoRef(id, GeoKind.point, 0)]);
    expect(c.sketchInfo!.free, 3);
    c.constrain(ConstraintType.horizontal, [GeoRef(id, GeoKind.line, 0)]);
    c.constrain(ConstraintType.distance, [GeoRef(id, GeoKind.line, 0)]);
    expect(c.sketchInfo!.free, 1);
    expect(c.sketchInfo!.fixed, isEmpty);
    c.constrain(ConstraintType.distance, [GeoRef(id, GeoKind.line, 1)]);
    expect(c.sketchInfo!.free, 0);
    expect(c.sketchInfo!.fixed, {id});
  });

  testWidgets('dimension dialog and the tool bar', (tester) async {
    final c = makeController();
    final a = rect(c, 10, 10, 100, 50);
    final tool = ConstraintTool();
    c.tool = tool;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          c.dimensionRequest.addListener(() {
            final refs = c.dimensionRequest.value;
            if (refs != null) {
              c.dimensionRequest.value = null;
              showDimensionDialog(context, c, refs);
            }
          });
          return ListenableBuilder(listenable: c, builder: (_, _) => Align(alignment: Alignment.bottomCenter, child: ConstraintBar(controller: c, tool: tool)));
        }),
      ),
    ));
    expect(find.text('No constraints yet'), findsOneWidget);
    // Pick the top edge, then empty space: its length.
    click(c, tool, a.live!.corners[0] + Offset(mm(50), 0));
    click(c, tool, const Offset(-500, -500));
    await tester.pumpAndSettle();
    expect(find.text('Dimension'), findsOneWidget);
    final field = find.widgetWithText(TextField, 'Length');
    await tester.enterText(field, '250');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(a.live!.width, closeTo(mm(250), 1e-3));
    expect(find.textContaining('degrees of freedom left'), findsOneWidget);
  });
}
