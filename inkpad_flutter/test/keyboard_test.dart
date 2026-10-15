import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/main.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';

import 'helpers/test_fonts.dart';

void main() {
  setUpAll(initTestFonts);

  testWidgets('typing in a size box goes to the box, not to shortcuts', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lib = LibraryController(MemoryDrawingStore());
    await lib.load();
    final d = InkDrawing(width: 1000, height: 800, units: 'mm', makeMode: true)
      ..activeLayer.elements.add(InkPath.live(LiveShape.inRect(LiveKind.rectangle, const Rect.fromLTWH(100, 100, 200, 100))));
    await lib.create(drawing: d, name: 'Box');
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Box'));
    await tester.pumpAndSettle();

    // Select it (shortcuts work while nothing is being typed into).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyA), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
    final w = find.widgetWithText(TextField, 'W');
    expect(w, findsOneWidget);

    await tester.tap(w);
    await tester.pump();
    // 1, 0 and letters aren't taken by the editor (they're typed).
    for (final key in [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit0, LogicalKeyboardKey.keyR]) {
      expect(await tester.sendKeyEvent(key), isFalse, reason: '$key');
    }
    // Delete and Backspace edit the box's text; they don't delete the shape.
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(find.widgetWithText(TextField, 'W'), findsOneWidget); // still selected: nothing deleted
  });
}
