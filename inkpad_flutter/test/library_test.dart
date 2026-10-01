import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/library/store_io.dart';
import 'package:inkpad/main.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/ui/drawing_canvas.dart';

void main() {
  group('LibraryController', () {
    test('create, rename, duplicate, delete persist to the store', () async {
      final store = MemoryDrawingStore();
      final lib = LibraryController(store);
      await lib.load();

      final a = await lib.create();
      final b = await lib.create();
      expect([a.name, b.name], ['Untitled', 'Untitled 2']);
      expect(store.files.length, 2);

      await lib.rename(a, '  Logo  ');
      final copy = await lib.duplicate(a);
      expect(copy.name, 'Logo copy');
      expect(lib.drawings.first, copy);

      await lib.delete(b);
      final reloaded = LibraryController(store);
      await reloaded.load();
      expect(reloaded.drawings.map((d) => d.name).toSet(), {'Logo', 'Logo copy'});
    });

    test('saveEdits moves drawing to the top and stores contents', () async {
      final store = MemoryDrawingStore();
      final lib = LibraryController(store);
      await lib.load();
      final first = await lib.create();
      await lib.create();

      final d = InkDrawing()..activeLayer.elements.add(InkPath.rect(const Rect.fromLTWH(0, 0, 5, 5)));
      await lib.saveEdits(first, d);
      expect(lib.drawings.first, first);

      final reloaded = LibraryController(store);
      await reloaded.load();
      expect(reloaded.drawings.first.drawing.allElements.length, 1);
    });
  });

  test('FileDrawingStore round-trips and skips bad files', () async {
    final dir = await Directory.systemTemp.createTemp('inkpad_test');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileDrawingStore(dir);

    final info = DrawingInfo(id: 'abc', name: 'Star', modified: DateTime(2026, 1, 2), drawing: InkDrawing());
    await store.save(info);
    await File('${dir.path}/broken.inkpad').writeAsString('not json');

    final all = await store.loadAll();
    expect(all.single.name, 'Star');
    expect(all.single.modified, DateTime(2026, 1, 2));

    await store.delete('abc');
    expect(await store.loadAll(), isEmpty);
  });

  testWidgets('new drawing, edit, go back, thumbnail and autosave', (tester) async {
    final store = MemoryDrawingStore();
    final lib = LibraryController(store);
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();
    expect(find.text('No drawings yet'), findsOneWidget);

    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();
    expect(find.text('Untitled'), findsOneWidget); // editor title

    // Draw a rectangle with the rectangle tool.
    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pump();
    final canvas = tester.getCenter(find.byType(DrawingCanvas));
    await tester.dragFrom(canvas, const Offset(80, 60));
    await tester.pumpAndSettle();

    // Autosave kicks in shortly after editing, without leaving the editor.
    await tester.pump(const Duration(seconds: 1));
    expect(lib.drawings.single.drawing.allElements.length, 1);
    expect(DrawingInfo.decode('x', store.files.values.single).drawing.allElements.length, 1);

    // Back to the library; the edit is saved.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Untitled'), findsOneWidget);
    final saved = DrawingInfo.decode('x', store.files.values.single);
    expect(saved.drawing.allElements.length, 1);
  });
}
