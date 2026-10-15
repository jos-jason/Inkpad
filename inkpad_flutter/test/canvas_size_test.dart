import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/ui/panels/canvas_size_dialog.dart';

void main() {
  DrawingController withSquare() {
    final c = DrawingController(drawing: InkDrawing(width: 600, height: 400));
    c.addElement(InkPath.rect(const Rect.fromLTWH(100, 100, 50, 50)));
    return c;
  }

  test('resizing keeps the artwork with the chosen part of the page', () {
    final c = withSquare();
    c.resizeCanvas(800, 500);
    expect(c.drawing.allElements.single.bounds.topLeft, const Offset(100, 100));
    c.resizeCanvas(1000, 700, anchor: Alignment.center);
    expect(c.drawing.allElements.single.bounds.topLeft, const Offset(200, 200));
    c.resizeCanvas(900, 600, anchor: Alignment.bottomRight);
    expect(c.drawing.allElements.single.bounds.topLeft, const Offset(100, 100));
    expect((c.drawing.width, c.drawing.height), (900, 600));
    c.undo();
    expect((c.drawing.width, c.drawing.height), (1000, 700));
  });

  test('fit to artwork', () {
    final c = withSquare();
    c.fitCanvasToArtwork(margin: 10);
    expect((c.drawing.width, c.drawing.height), (70, 70));
    expect(c.drawing.allElements.single.bounds.topLeft, const Offset(10, 10));
  });

  testWidgets('the dialog sets a preset size', (tester) async {
    final c = withSquare();
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(onPressed: () => showCanvasSizeDialog(context, c), child: const Text('open'))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sizes'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Letter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resize'));
    await tester.pumpAndSettle();
    // The page was landscape, so Letter is too.
    expect((c.drawing.width, c.drawing.height), (792, 612));
  });
}
