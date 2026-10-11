
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/main.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/tools/tool.dart';
import 'package:inkpad/ui/drawing_canvas.dart';

bool hasHandles(InkPath p, int i) => p.nodes[i].hasInPoint || p.nodes[i].hasOutPoint;

void main() {
  test('select tool: a double click on a point toggles its handles', () {
    final c = DrawingController();
    final rect = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 50));
    c.addElement(rect);
    c.select(rect);
    c.tool = SelectionTool();

    void click(Offset p, int count) {
      c.tool.begin(c, ToolEvent(p, 1, count: count));
      c.tool.end(c, ToolEvent(p, 1, count: count));
    }

    click(const Offset(100, 0), 1);
    click(const Offset(100, 0), 2);
    expect(hasHandles(rect, 1), isTrue);
    expect(rect.nodes[1].isCorner, isFalse); // smooth

    click(const Offset(100, 0), 1);
    click(const Offset(100, 0), 2);
    expect(hasHandles(rect, 1), isFalse);

    // A triple click doesn't toggle a third time.
    click(const Offset(100, 0), 3);
    expect(hasHandles(rect, 1), isFalse);

    c.undo();
    expect(hasHandles(c.drawing.activeLayer.elements.single as InkPath, 1), isTrue);
  });

  test('a double click elsewhere on the shape does not convert anything', () {
    final c = DrawingController();
    final rect = InkPath.rect(const Rect.fromLTWH(0, 0, 100, 50))..fill = const InkColor(0, 0, 0);
    c.addElement(rect);
    c.select(rect);
    c.tool = SelectionTool();
    c.tool.begin(c, const ToolEvent(Offset(50, 25), 1, count: 2));
    c.tool.end(c, const ToolEvent(Offset(50, 25), 1, count: 2));
    expect(rect.nodes.every((n) => !n.hasInPoint && !n.hasOutPoint), isTrue);
    expect(c.canUndo, isFalse);
  });

  testWidgets('double tapping a point on the canvas toggles its handles', (tester) async {
    final lib = LibraryController(MemoryDrawingStore());
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();

    // Draw a rectangle, then switch to the select tool.
    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pump();
    final center = tester.getCenter(find.byType(DrawingCanvas));
    await tester.dragFrom(center, const Offset(100, 60));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.near_me_outlined));
    await tester.pump();

    final state = tester.state<DrawingCanvasState>(find.byType(DrawingCanvas));
    final canvasOrigin = tester.getTopLeft(find.byType(DrawingCanvas));
    InkPath rect() => (state.widget.controller.drawing.activeLayer.elements.single as InkPath);
    final corner = canvasOrigin + state.toScreen(rect().nodes[2].anchorPoint);

    // Taps with explicit event times (test taps otherwise all share time 0).
    var clock = const Duration(seconds: 10);
    Future<void> tapAfter(int ms) async {
      clock += Duration(milliseconds: ms);
      final g = await tester.createGesture();
      await g.down(corner, timeStamp: clock);
      await g.up(timeStamp: clock + const Duration(milliseconds: 40));
      await tester.pump();
    }

    // Two slow taps are two single clicks: nothing changes.
    await tapAfter(0);
    await tapAfter(600);
    expect(hasHandles(rect(), 2), isFalse);

    // A quick double tap adds handles; another removes them.
    await tapAfter(600);
    await tapAfter(120);
    expect(hasHandles(rect(), 2), isTrue);

    await tapAfter(600);
    await tapAfter(120);
    expect(hasHandles(rect(), 2), isFalse);
  });
}
