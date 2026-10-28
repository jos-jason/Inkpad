import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/main.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/ui/chrome/chrome.dart';

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

  for (final phone in [true, false]) {
    testWidgets('panels stay above the keyboard and it can be put away (${phone ? 'phone' : 'iPad'})', (tester) async {
      tester.view.physicalSize = phone ? const Size(430, 932) : const Size(1024, 1366);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final field = FocusNode();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPopover<void>(
                  anchor: context,
                  builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(height: 200, child: Text('Describe what to draw')),
                    TextField(focusNode: field, autofocus: true, onTapOutside: (_) => field.unfocus()),
                    TextButton(onPressed: () {}, child: const Text('Draw')),
                  ]),
                ),
                child: const Text('AI'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('AI'));
      await tester.pumpAndSettle();
      // The keyboard comes up over the bottom 340 pixels.
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pumpAndSettle();
      final screen = tester.view.physicalSize.height;
      expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(screen - 340));
      expect(tester.getRect(find.text('Draw')).bottom, lessThanOrEqualTo(screen - 340));
      expect(field.hasFocus, isTrue);
      // Tapping outside the text box puts the keyboard away.
      await tester.tap(find.text('Describe what to draw'));
      await tester.pump();
      expect(field.hasFocus, isFalse);
    });
  }
}
