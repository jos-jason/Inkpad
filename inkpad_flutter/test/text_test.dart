import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/svg/svg_importer.dart';
import 'package:inkpad/text/font_file.dart';
import 'package:inkpad/text/font_library.dart';

import 'helpers/test_fonts.dart';

void main() {
  setUpAll(initTestFonts);

  group('fonts', () {
    test('bundled Lato faces are read with names, weights and italics', () {
      final lib = FontLibrary.instance;
      expect(lib.families, contains('Lato'));
      expect(lib.stylesOf('Lato').map((f) => f.style), ['Regular', 'Italic', 'Bold', 'Bold Italic']);
      expect(lib.find('Lato', 'Bold')!.weight, 700);
      expect(lib.find('Lato', 'Bold Italic')!.italic, isTrue);
      expect(lib.defaultFamily, 'Lato'); // no Helvetica in tests
      expect(lib.find('Nope', 'Regular'), isNull);
    });

    test('font collections (.ttc) split into faces', () {
      const helvetica = '/System/Library/Fonts/Helvetica.ttc';
      if (!File(helvetica).existsSync()) return; // macOS only
      final bytes = File(helvetica).readAsBytesSync();
      final faces = readFontFaces(bytes, helvetica);
      expect(faces.map((f) => f.style), containsAll(['Regular', 'Bold', 'Oblique']));
      final face = faces.firstWhere((f) => f.style == 'Bold');
      final single = extractFace(bytes, face.index);
      expect(readFontFaces(single, 'x').single.style, 'Bold');
    });

    test('importing a font adds it to the app without installing it', () async {
      final lib = FontLibrary.instance;
      final bytes = File('assets/fonts/Lato-Bold.ttf').readAsBytesSync();
      expect(await lib.importFont(bytes, 'MyFont.ttf'), isNotEmpty);
      expect(await lib.importFont(Uint8List.fromList([1, 2, 3]), 'junk.ttf'), isEmpty);
    });
  });

  group('InkText', () {
    InkText text(String s, {double? width, TextAlignment align = TextAlignment.left}) =>
        InkText(text: s, fontFamily: 'Lato', fontSize: 100, width: width, alignment: align, fill: InkColor.black);

    test('point text sits on its first baseline at the origin', () {
      final t = text('Hg');
      final b = t.toFlutterPath().getBounds();
      expect(b.left, closeTo(0, 10));
      expect(b.top, lessThan(-60)); // capital H rises above the baseline
      expect(b.bottom, greaterThan(10)); // g descends below it
      expect(t.outlines.length, 4); // H (1) + g (3 contours)
      expect(t.hitTest(const Offset(30, -30), 0), isTrue);
      expect(t.hitTest(const Offset(30, 300), 0), isFalse);
    });

    test('point text alignment is around the anchor', () {
      final c = text('Hello', align: TextAlignment.center).toFlutterPath().getBounds();
      expect(c.center.dx, closeTo(0, 5));
      final r = text('Hello', align: TextAlignment.right).toFlutterPath().getBounds();
      expect(r.right, closeTo(0, 5));
    });

    test('area text wraps to its width and starts below the top edge', () {
      final t = text('Hello there world', width: 400);
      expect(t.lines.length, 3);
      expect(t.lines.first.baseline, closeTo(98.7, 0.5)); // Lato's ascender at 100pt
      expect(t.bounds.width, closeTo(400, 0.01));
      expect(t.toFlutterPath().getBounds().top, greaterThan(0));
      final centered = text('Hi', width: 400, align: TextAlignment.center);
      expect(centered.toFlutterPath().getBounds().center.dx, closeTo(200, 5));
    });

    test('placement moves and scales text; style applies to letters', () {
      final t = text('Hi')
        ..fill = const InkGradient(stops: [GradientStop(0, InkColor.black), GradientStop(1, InkColor.white)]);
      final before = t.toFlutterPath().getBounds();
      t.transform(Affine.scale(2, 2).then(Affine.translation(100, 50)));
      final after = t.toFlutterPath().getBounds();
      expect(after.width, closeTo(before.width * 2, 0.5));
      expect(after.left, closeTo(before.left * 2 + 100, 0.5));
      expect((t.fill as InkGradient).geometry, isNotNull); // gradient turned with it
    });

    test('a missing font falls back to Lato', () {
      final t = InkText(text: 'Hi', fontFamily: 'Not Installed', fontSize: 50);
      expect(t.fontAvailable, isFalse);
      expect(t.face.info.family, 'Lato');
      expect(t.isEmpty, isFalse);
    });

    test('empty text has no outlines but keeps a box', () {
      final t = text('', width: 200);
      expect(t.isEmpty, isTrue);
      expect(t.bounds.width, 200);
    });

    test('JSON and SVG export', () {
      final t = text('A & B\nline two', width: 500, align: TextAlignment.right)
        ..placement = Affine.translation(10, 20)
        ..stroke = const StrokeStyle(width: 2);
      final copy = InkText.fromJson(t.toJson());
      expect(copy.toJson(), t.toJson());
      final d = InkDrawing()..activeLayer.elements.add(t);
      final svg = d.toSvg();
      expect(svg, contains('<text transform="matrix(1 0 0 1 10 20)" font-family="Lato" font-size="100"'));
      expect(svg, contains('A &amp; B</tspan>'));
      expect(svg, contains('inkpad:width="500"'));
      expect(svg, contains('inkpad:text="A &amp; B&#10;line two"'));
      expect(RegExp('<tspan').allMatches(svg).length, 2);
    });
  });

  group('InkTextPath', () {
    test('letters follow the path; text past the end is hidden', () {
      final guide = InkPath(nodes: [const BezierNode.anchor(Offset(0, 100)), const BezierNode.anchor(Offset(300, 100))]);
      final tp = InkTextPath(text: 'Hello', guide: guide, fontFamily: 'Lato', fontSize: 50, fill: InkColor.black);
      final b = tp.toFlutterPath().getBounds();
      expect(b.bottom, closeTo(100, 2)); // sitting on the line
      expect(b.left, closeTo(0, 6));
      expect(tp.offsetNearest(const Offset(150, 90)), closeTo(150, 0.5));

      final count = tp.outlines.length;
      tp.startOffset = 250; // most letters fall off the end
      expect(tp.outlines.length, lessThan(count));

      // A vertical path turns the letters.
      final down = InkTextPath(
        text: 'HHH',
        guide: InkPath(nodes: [const BezierNode.anchor(Offset(0, 0)), const BezierNode.anchor(Offset(0, 300))]),
        fontFamily: 'Lato',
        fontSize: 50,
      );
      final db = down.toFlutterPath().getBounds();
      expect(db.height, greaterThan(db.width * 2)); // the letters run down the path

      final copy = InkTextPath.fromJson(tp.toJson());
      expect(copy.toJson(), tp.toJson());
      final svg = (InkDrawing()..activeLayer.elements.add(tp)).toSvg();
      expect(svg, contains('<textPath xlink:href="#textpath1" startOffset="250">Hello</textPath>'));
      expect(svg, contains('<path id="textpath1" d="M0 100L300 100"/>'));
    });
  });

  group('SVG text import', () {
    String svg(String body) =>
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 400 400">$body</svg>';

    test('point text keeps its anchor, font, size, alignment and fill', () {
      final r = importSvg(svg('<text x="50" y="80" font-family="\'Lato\', sans-serif" font-size="30" '
          'font-weight="bold" text-anchor="middle" fill="#ff0000">Hi  <tspan>there</tspan></text>'));
      final t = r.drawing.layers.first.elements.single as InkText;
      expect(t.text, 'Hi there');
      expect((t.fontFamily, t.fontStyle, t.fontSize), ('Lato', 'Bold', 30));
      expect(t.alignment, TextAlignment.center);
      expect(t.width, isNull);
      expect(t.placement.apply(Offset.zero), const Offset(50, 80));
      expect((t.fill as InkColor).hexValue, '#ff0000');
    });

    test('tspans on new lines become lines; missing fonts keep their name', () {
      final r = importSvg(svg('<text font-family="Imaginary Sans" font-size="20" font-style="italic">'
          '<tspan x="10" y="20">one</tspan><tspan x="10" y="44">two</tspan></text>'));
      final t = r.drawing.layers.first.elements.single as InkText;
      expect(t.text, 'one\ntwo');
      expect((t.fontFamily, t.fontStyle), ('Imaginary Sans', 'Italic'));
      expect(t.placement.apply(Offset.zero), const Offset(10, 20));
      expect(r.warnings.join(), contains('fonts'));
      expect(t.outlines, isNotEmpty); // drawn with the fallback meanwhile
    });

    test("Inkpad's own text round-trips through SVG", () {
      final area = InkText(
        text: 'Wrapping text in a box',
        fontFamily: 'Lato',
        fontStyle: 'Bold Italic',
        fontSize: 40,
        width: 200,
        alignment: TextAlignment.right,
        placement: Affine.translation(30, 40),
        fill: InkColor.black,
      );
      final point = InkText(text: 'Point', fontFamily: 'Lato', fontSize: 24, alignment: TextAlignment.center, placement: Affine.translation(200, 300), fill: InkColor.black);
      final guide = InkPath(nodes: [const BezierNode.anchor(Offset(0, 100)), const BezierNode.anchor(Offset(300, 100))]);
      final onPath = InkTextPath(text: 'Along', guide: guide, fontFamily: 'Lato', fontSize: 30, startOffset: 40, fill: InkColor.black);
      final d = InkDrawing()..activeLayer.elements.addAll([area, point, onPath]);
      final back = importSvg(d.toSvg()).drawing.layers.expand((l) => l.elements).toList();
      expect(back, hasLength(3));
      final a = back[0] as InkText, p = back[1] as InkText, tp = back[2] as InkTextPath;
      expect((a.text, a.width, a.alignment, a.fontStyle, a.fontSize), (area.text, 200, TextAlignment.right, 'Bold Italic', 40));
      expect(a.bounds.left, closeTo(area.bounds.left, 0.01));
      expect(a.bounds.top, closeTo(area.bounds.top, 0.01));
      expect((p.text, p.alignment), ('Point', TextAlignment.center));
      expect(p.bounds.center.dx, closeTo(point.bounds.center.dx, 0.01));
      expect(p.bounds.bottom, closeTo(point.bounds.bottom, 0.01));
      expect((tp.text, tp.startOffset, tp.fontSize), ('Along', 40, 30));
      expect(tp.guide.svgPathData, guide.svgPathData);
    });

    test('textPath with a percentage offset and a scaled group', () {
      final r = importSvg(svg('<defs><path id="p" d="M0 0L100 0"/></defs>'
          '<g transform="scale(2)"><text font-size="10"><textPath xlink:href="#p" startOffset="50%">ab</textPath></text></g>'));
      final tp = r.drawing.layers.first.elements.single as InkTextPath;
      expect(tp.pathLength, closeTo(200, 0.01));
      expect(tp.startOffset, closeTo(100, 0.01));
      expect(tp.fontSize, 20);
    });
  });

  group('text editing', () {
    test('create, type, and empty text disappears', () {
      final c = DrawingController();
      final t = c.createText(at: const Offset(10, 10));
      expect(c.editingText, same(t));
      c.updateEditingText('Hello');
      expect(t.text, 'Hello');
      c.endEditing();
      expect(c.drawing.activeLayer.elements, [t]);

      c.beginEditing(t);
      c.updateEditingText('  ');
      c.selectNone(); // ends editing
      expect(c.editingText, isNull);
      expect(c.drawing.activeLayer.elements, isEmpty);
      c.undo();
      expect((c.drawing.activeLayer.elements.single as InkText).text, 'Hello');
    });

    test('area text is at least the minimum width', () {
      final c = DrawingController();
      final t = c.createText(area: Rect.fromLTWH(0, 0, 5, 50));
      expect(t.width, InkText.minimumWidth);
    });

    test('text style applies to the selection and is undoable', () {
      final c = DrawingController();
      final t = c.createText(at: Offset.zero)..text = 'Hi';
      c.endEditing();
      c.setTextStyle(family: 'Lato', style: 'Bold', size: 60, alignment: TextAlignment.right);
      expect((t.fontStyle, t.fontSize, t.alignment), ('Bold', 60, TextAlignment.right));
      c.undo();
      final restored = c.drawing.activeLayer.elements.single as InkText;
      expect(restored.fontSize, isNot(60));
      // A family without the style falls back to its regular face.
      c.setTextStyle(family: 'Lato', style: 'Black');
      expect(c.fontStyle, 'Regular');
      c.setTextStyle(family: 'Lato', style: 'Italic');
      c.setTextStyle(family: 'Imaginary');
      expect(c.fontStyle, 'Regular');
    });

    test('create outlines turns text into one compound path', () {
      final c = DrawingController();
      final t = c.createText(at: const Offset(0, 100))
        ..text = 'Ok'
        ..fill = const InkColor(1, 0, 0);
      c.endEditing();
      c.select(t);
      expect(c.canCreateOutlines, isTrue);
      c.createOutlines();
      final o = c.drawing.activeLayer.elements.single as InkCompoundPath;
      expect(o.subpaths.length, greaterThanOrEqualTo(2));
      expect(o.fill, const InkColor(1, 0, 0));
      expect(o.bounds.center.dx, closeTo(t.bounds.center.dx, 0.5));
    });

    test('place text on path uses the selected text', () {
      final c = DrawingController();
      final path = InkPath(nodes: [const BezierNode.anchor(Offset(0, 100)), const BezierNode.anchor(Offset(300, 100))]);
      final t = InkText(text: 'Curvy', fontFamily: 'Lato', fontSize: 30, fill: InkColor.black);
      c.drawing.activeLayer.elements.addAll([path, t]);
      c.select(path);
      c.select(t, extend: true);
      expect(c.canPlaceTextOnPath, isTrue);
      c.placeTextOnPath();
      final tp = c.drawing.activeLayer.elements.single as InkTextPath;
      expect((tp.text, tp.fontSize), ('Curvy', 30));
      expect(c.editingText, isNull);

      // A path alone gets placeholder text, ready to type.
      final c2 = DrawingController();
      final p2 = InkPath(nodes: [const BezierNode.anchor(Offset.zero), const BezierNode.anchor(Offset(100, 0))]);
      c2.drawing.activeLayer.elements.add(p2);
      c2.select(p2);
      c2.placeTextOnPath();
      expect(c2.editingText, isA<InkTextPath>());
    });
  });
}
