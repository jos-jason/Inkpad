import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/export/pdf_export.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/svg/svg_importer.dart';

import 'helpers/test_fonts.dart';

const red = InkColor(1, 0, 0), blue = InkColor(0, 0, 1);

InkText sale() => InkText(
      runs: const [TextRun('Summer '), TextRun('SALE', TextRunStyle(fontStyle: 'Bold', fontSize: 60, fill: red))],
      fontFamily: 'Lato',
      fontSize: 30,
      placement: Affine.translation(10, 100),
      fill: InkColor.black,
    );

void main() {
  setUpAll(initTestFonts);

  group('runs', () {
    test('editing keeps styles; new letters take the style before them', () {
      const runs = [TextRun('ab'), TextRun('CD', TextRunStyle(fontSize: 9)), TextRun('ef')];
      expect(runs.edited('abCxDef'), const [TextRun('ab'), TextRun('CxD', TextRunStyle(fontSize: 9)), TextRun('ef')]);
      expect(runs.edited('abef'), const [TextRun('abef')]); // the styled letters went
      expect(runs.edited('abCDefg').last, const TextRun('efg'));
      expect(runs.edited('XabCDef').first, const TextRun('Xab'));
      expect(runs.edited(''), const [TextRun('')]);
      expect(runs.edited('aZf'), const [TextRun('aZf')]); // replaced across runs
    });

    test('restyling a stretch splits and rejoins runs', () {
      const runs = [TextRun('hello world')];
      final r = runs.restyle(6, 11, (s) => s.merge(const TextRunStyle(fill: red)));
      expect(r, const [TextRun('hello '), TextRun('world', TextRunStyle(fill: red))]);
      expect(r.restyle(0, 11, (s) => s.without(fill: true)), const [TextRun('hello world')]);
      expect(r.styleAt(7).fill, red);
      expect(r.styleAt(11).fill, red); // at the end: the last letter's
    });
  });

  group('styled text', () {
    test('letters in another size make their line taller; colors draw apart', () async {
      final plain = InkText(text: 'Summer SALE', fontFamily: 'Lato', fontSize: 30, placement: Affine.translation(10, 100));
      final t = sale();
      expect(t.text, 'Summer SALE');
      expect(t.layoutBox.top, lessThan(plain.layoutBox.top - 10)); // taller
      expect(t.layoutBox.width, greaterThan(plain.layoutBox.width));
      expect(t.paintGroups.map((g) => g.$1), [InkColor.black, red]);

      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 400, 150), Paint()..color = const Color(0xFFFFFFFF));
      t.render(canvas);
      final img = await rec.endRecording().toImage(400, 150);
      final d = (await img.toByteData())!;
      var reds = 0, blacks = 0;
      for (var i = 0; i < 400 * 150; i++) {
        final r = d.getUint8(i * 4), g = d.getUint8(i * 4 + 1);
        if (r > 200 && g < 60) reds++;
        if (r < 60 && g < 60) blacks++;
      }
      expect(reds, greaterThan(200));
      expect(blacks, greaterThan(200));
    });

    test('wrapping area text breaks between words across styles', () {
      final t = InkText(
        runs: const [TextRun('one two '), TextRun('three', TextRunStyle(fontSize: 40)), TextRun(' four five six')],
        fontFamily: 'Lato',
        fontSize: 20,
        width: 120,
      );
      final lines = t.lines;
      expect(lines.length, greaterThan(2));
      expect(lines.every((l) => l.width <= 120 + 1e-6), isTrue);
      expect(lines.map((l) => l.text.trim()).join(' '), 'one two three four five six');
      // A line with the big word sits lower than spacing for 20 pt alone.
      final bigLine = lines.indexWhere((l) => l.text.contains('three'));
      if (bigLine > 0) expect(lines[bigLine].baseline - lines[bigLine - 1].baseline, greaterThan(30));
    });

    test('a word too long for the box breaks between letters', () {
      final t = InkText(text: 'Supercalifragilistic', fontFamily: 'Lato', fontSize: 30, width: 80);
      expect(t.lines.length, greaterThan(2));
      expect(t.lines.every((l) => l.width <= 80 + 1e-6), isTrue);
      expect(t.lines.map((l) => l.text).join(), 'Supercalifragilistic');
    });

    test('JSON and SVG keep the runs', () {
      final t = sale();
      expect(InkText.fromJson(jsonDecode(jsonEncode(t.toJson()))).runs, t.runs);
      expect(InkText.fromJson(InkText(text: 'x', fontFamily: 'Lato').toJson()).runs, const [TextRun('x')]);
      final svg = (InkDrawing()..activeLayer.elements.add(t)).toSvg();
      expect(svg, contains('<tspan font-family="Lato" font-size="60" font-weight="700" font-style="normal" fill="#ff0000">SALE</tspan>'));
      final back = importSvg(svg).drawing.allElements.single as InkText;
      expect(back.runs, t.runs);
    });

    test('styled tspans from other apps become runs', () {
      final r = importSvg('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200">'
          '<text x="10" y="50" font-family="Lato" font-size="20" fill="#000">Big <tspan font-size="40" fill="#0000ff">blue</tspan>'
          ' <tspan font-weight="bold">bold</tspan>  end</text></svg>');
      final t = r.drawing.allElements.single as InkText;
      expect(t.text, 'Big blue bold end');
      expect(t.runs, const [
        TextRun('Big '),
        TextRun('blue', TextRunStyle(fontSize: 40, fill: blue)),
        TextRun(' '),
        TextRun('bold', TextRunStyle(fontStyle: 'Bold')),
        TextRun(' end'),
      ]);
    });

    test('PDF and outlines keep the colors', () async {
      final pdf = latin1.decode(await drawingToPdf(InkDrawing(width: 400, height: 200)..activeLayer.elements.add(sale()), compress: false));
      expect(pdf, contains('1 0 0 rg'));
      final c = DrawingController();
      final t = sale();
      c.addElement(t);
      c.select(t);
      c.createOutlines();
      final g = c.drawing.allElements.single as InkGroup;
      expect(g.elements.map((e) => (e as InkStylable).fill), [InkColor.black, red]);
    });
  });

  group('editing', () {
    test('panels style the selected letters while typing, or the whole text', () {
      final c = DrawingController();
      final t = c.createText(at: const Offset(10, 50));
      c.updateEditingText('Hello world');
      c.setEditingRange(const TextRange(start: 6, end: 11));
      c.setTextStyle(size: 50);
      c.fillPaint = red;
      c.applyStyleToSelection(fill: true);
      expect(t.runs, [
        const TextRun('Hello '),
        TextRun('world', TextRunStyle(fontSize: 50, fill: red)),
      ]);
      // The panels show the selected letters' style.
      c.setEditingRange(const TextRange(start: 0, end: 2));
      expect((c.fontSize, c.fillPaint), (t.fontSize, t.fill));
      c.setEditingRange(const TextRange(start: 7, end: 8));
      expect((c.fontSize, c.fillPaint), (50, red));
      // Typing more after "world" continues its style.
      c.updateEditingText('Hello worlds');
      expect(t.runs.last.text, 'worlds');
      c.endEditing();
      // The whole text: overrides go.
      c.select(t);
      c.setTextStyle(size: 12);
      expect(t.runs.every((r) => r.style.fontSize == null), isTrue);
      c.fillPaint = blue;
      c.applyStyleToSelection(fill: true);
      expect(t.isStyled, isFalse);
      // Undo brings the styled letters back.
      c.undo();
      c.undo();
      expect((c.drawing.allElements.single as InkText).isStyled, isTrue);
    });
  });
}
