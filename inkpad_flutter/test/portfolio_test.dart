import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/library/store_io.dart';
import 'package:inkpad/main.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';

import 'helpers/test_fonts.dart';

void main() {
  setUpAll(initTestFonts);

  group('portfolios', () {
    test('create, move drawings in and out, rename, delete; all persisted', () async {
      final store = MemoryDrawingStore();
      final lib = LibraryController(store);
      await lib.load();
      final a = await lib.create(name: 'Logo');
      final b = await lib.create(name: 'Poster');
      final p = await lib.createPortfolio('  Client work ');
      expect(p.name, 'Client work');
      expect((await lib.createPortfolio()).name, 'Portfolio');
      expect(lib.uniquePortfolioName(), 'Portfolio 2');

      await lib.move([a, b], p.id);
      expect(lib.drawingsIn(p.id).toSet(), {a, b});
      expect(lib.drawingsIn(null), isEmpty);
      final inside = await lib.create(portfolio: p.id);
      expect(inside.portfolio, p.id);
      expect((await lib.duplicate(a)).portfolio, p.id);
      await lib.renamePortfolio(p, 'Clients');

      final reloaded = LibraryController(store);
      await reloaded.load();
      final rp = reloaded.portfolios.firstWhere((x) => x.id == p.id);
      expect(rp.name, 'Clients');
      expect(reloaded.drawingsIn(p.id).length, 4);

      await lib.move([a], null);
      expect(a.portfolio, isNull);
      // Deleting keeps the drawings (back in the gallery) unless asked.
      await lib.deletePortfolio(p);
      expect(lib.drawings.length, 4);
      expect(lib.drawings.every((d) => d.portfolio == null), isTrue);
      final q = await lib.createPortfolio('Temp');
      await lib.move([b], q.id);
      await lib.deletePortfolio(q, deleteDrawings: true);
      expect(lib.drawings.contains(b), isFalse);
      expect(store.files.containsKey(b.id), isFalse);
    });

    test('drawings in a portfolio that no longer exists come back to the gallery', () async {
      final store = MemoryDrawingStore();
      final lib = LibraryController(store);
      await lib.load();
      final p = await lib.createPortfolio('Gone');
      await lib.create(portfolio: p.id);
      store.portfolios = null; // the portfolio list was lost
      final reloaded = LibraryController(store);
      await reloaded.load();
      expect(reloaded.drawingsIn(null).length, 1);
    });

    test('the file store keeps portfolios beside the drawings', () async {
      final dir = await Directory.systemTemp.createTemp('inkpad_portfolios');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileDrawingStore(dir);
      final p = PortfolioInfo(id: 'p1', name: 'Sketches', created: DateTime(2026, 1, 1));
      await store.savePortfolios([p]);
      await store.save(DrawingInfo(id: 'd1', name: 'A', modified: DateTime(2026), drawing: InkDrawing(), portfolio: 'p1'));
      expect((await store.loadPortfolios()).single.name, 'Sketches');
      expect((await store.loadAll()).single.portfolio, 'p1');
    });
  });

  test('search matches names, portfolio names and text in drawings', () async {
    final lib = LibraryController(MemoryDrawingStore());
    await lib.load();
    final p = await lib.createPortfolio('Wedding');
    await lib.create(name: 'Invitation', portfolio: p.id);
    final menu = await lib.create(
      name: 'Menu card',
      drawing: InkDrawing()..activeLayer.elements.add(InkText(text: 'Chocolate cake', fontFamily: 'Lato')),
    );
    await lib.create(name: 'Logo sketch');

    expect(lib.search('logo', everywhere: true).map((d) => d.name), ['Logo sketch']);
    expect(lib.search('CAKE', everywhere: true), [menu]); // text inside the drawing
    expect(lib.search('wedding', everywhere: true).map((d) => d.name), ['Invitation']); // its portfolio
    expect(lib.search('menu chocolate', everywhere: true), [menu]); // every word
    expect(lib.search('menu wedding', everywhere: true), isEmpty);
    expect(lib.search('invitation', within: null), isEmpty); // only loose drawings
    expect(lib.search('', within: p.id).length, 1);
    expect(lib.searchPortfolios('wed').single, p);
  });

  testWidgets('gallery: search, new portfolio, move a drawing in, open it, new drawing inside', (tester) async {
    final lib = LibraryController(MemoryDrawingStore());
    await lib.load();
    await lib.create(name: 'Logo');
    await lib.create(name: 'Poster');
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();

    // Search.
    await tester.enterText(find.byType(SearchBar), 'log');
    await tester.pumpAndSettle();
    expect(find.text('Logo'), findsOneWidget);
    expect(find.text('Poster'), findsNothing);
    await tester.enterText(find.byType(SearchBar), 'zzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing matches'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Poster'), findsOneWidget);

    // New portfolio.
    await tester.tap(find.byTooltip('New portfolio'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Brand');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Brand'), findsOneWidget);
    expect(find.text('0 drawings'), findsOneWidget);

    // Move "Logo" into it from the drawing's menu.
    final logoCard = find.ancestor(of: find.text('Logo'), matching: find.byType(Card));
    final more = find.descendant(of: logoCard, matching: find.byTooltip('More'));
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Portfolio…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Brand').last);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('1 drawing'), findsOneWidget);
    expect(find.text('Logo'), findsNothing); // no longer loose

    // Open the portfolio: it shows its drawing; new drawings go in it.
    await tester.tap(find.text('Brand'));
    await tester.pumpAndSettle();
    expect(find.text('Logo'), findsOneWidget);
    expect(find.text('Poster'), findsNothing);
    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final brand = lib.portfolios.single;
    expect(lib.drawingsIn(brand.id).length, 2);
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(find.text('Untitled'), findsOneWidget); // back in the portfolio
  });

  testWidgets('rename a drawing from inside it', (tester) async {
    final lib = LibraryController(MemoryDrawingStore());
    await lib.load();
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rename drawing'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'My poster');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('My poster @'), findsOneWidget);
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(find.text('My poster'), findsOneWidget);
    expect(lib.drawings.single.name, 'My poster');
  });

  testWidgets('new drawings ask for a name; cancel makes none', (tester) async {
    final lib = LibraryController(MemoryDrawingStore());
    await lib.load();
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Untitled'), findsOneWidget); // suggested
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(lib.drawings, isEmpty);

    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Birthday card');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Birthday card @'), findsOneWidget); // straight into the editor
    expect(lib.drawings.single.name, 'Birthday card');
  });
}

