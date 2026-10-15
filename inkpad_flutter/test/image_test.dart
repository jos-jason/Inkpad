import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/svg/svg_importer.dart';
import 'package:inkpad/tools/tool.dart';

/// A PNG header claiming [w]×[h] (enough for sniffing; not decodable).
/// [salt] changes the bytes, so different fakes get different ids.
Uint8List fakePng(int w, int h, [int salt = 0]) {
  final b = Uint8List(33 + 4)..setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]);
  b.setAll(12, 'IHDR'.codeUnits);
  ByteData.sublistView(b)
    ..setUint32(16, w)
    ..setUint32(20, h)
    ..setUint32(33, salt);
  return b;
}

/// A minimal JPEG header with an EXIF orientation and a SOF0 size.
Uint8List fakeJpeg(int w, int h, {int orientation = 1}) {
  final exif = <int>[
    ...'Exif'.codeUnits, 0, 0, // identifier
    0x4D, 0x4D, 0, 42, 0, 0, 0, 8, // big-endian TIFF header, IFD at 8
    0, 1, // one entry
    0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0, // orientation (SHORT)
    0, 0, 0, 0,
  ];
  return Uint8List.fromList([
    0xFF, 0xD8,
    0xFF, 0xE1, (exif.length + 2) >> 8, (exif.length + 2) & 0xFF, ...exif,
    0xFF, 0xC0, 0, 17, 8, h >> 8, h & 0xFF, w >> 8, w & 0xFF, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0xFF, 0xD9,
  ]);
}

/// A real, decodable PNG made with Flutter.
Future<Uint8List> realPng(WidgetTester tester, int w, int h) async {
  late Uint8List bytes;
  await tester.runAsync(() async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.red);
    final img = await rec.endRecording().toImage(w, h);
    bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  });
  return bytes;
}

void main() {
  group('sniffImage', () {
    test('formats and sizes', () {
      expect(sniffImage(fakePng(640, 480)), (mimeType: 'image/png', width: 640, height: 480));
      final gif = Uint8List.fromList([...'GIF89a'.codeUnits, 0x20, 0x01, 0x10, 0x00]);
      expect(sniffImage(gif), (mimeType: 'image/gif', width: 288, height: 16));
      final bmp = Uint8List(26)..setAll(0, 'BM'.codeUnits);
      ByteData.sublistView(bmp)
        ..setInt32(18, 30, Endian.little)
        ..setInt32(22, -20, Endian.little); // top-down bitmaps have negative height
      expect(sniffImage(bmp), (mimeType: 'image/bmp', width: 30, height: 20));
      final webp = Uint8List(30)
        ..setAll(0, 'RIFF'.codeUnits)
        ..setAll(8, 'WEBPVP8X'.codeUnits)
        ..setAll(24, [99, 0, 0, 49, 0, 0]); // 100 × 50, stored minus one
      expect(sniffImage(webp), (mimeType: 'image/webp', width: 100, height: 50));
      expect(sniffImage(Uint8List.fromList(utf8.encode('not an image'))), isNull);
      expect(sniffImage(Uint8List.fromList([0x89, 0x50])), isNull); // truncated
    });

    test('JPEG size honours EXIF rotation', () {
      expect(sniffImage(fakeJpeg(400, 300)), (mimeType: 'image/jpeg', width: 400, height: 300));
      // Orientation 6 = rotated 90°: a portrait phone photo stored sideways.
      expect(sniffImage(fakeJpeg(400, 300, orientation: 6)), (mimeType: 'image/jpeg', width: 300, height: 400));
    });

    test('images are content-addressed', () {
      final a = ImageData.register(fakePng(10, 10, 1))!;
      expect(ImageData.register(fakePng(10, 10, 1)), same(a));
      expect(ImageData.register(fakePng(10, 10, 2)), isNot(same(a)));
      expect(ImageData.lookup(a.id), same(a));
    });
  });

  group('placing and editing images', () {
    test('placed images are centered and scaled down (never up) to fit', () {
      final c = DrawingController(drawing: InkDrawing(width: 800, height: 600));
      expect(c.placeImage(fakePng(1600, 400, 3)), isTrue);
      final big = c.selection.single as InkImage;
      expect(big.bounds, const Rect.fromLTWH(0, 200, 800, 200));

      expect(c.placeImage(fakePng(100, 50, 4)), isTrue);
      expect(c.selection.single.bounds, const Rect.fromLTWH(350, 275, 100, 50));
      expect(c.placeImage(Uint8List.fromList([1, 2, 3])), isFalse);

      c.undo();
      expect(c.drawing.activeLayer.elements.single, isA<InkImage>());
    });

    test('hit testing follows rotation', () {
      final img = InkImage(ImageData.register(fakePng(100, 20, 5))!,
          placement: Affine.rotationAbout(const Offset(50, 10), 3.141592653589793 / 2));
      expect(img.hitTest(const Offset(50, 50), 0), isTrue); // inside once rotated
      expect(img.hitTest(const Offset(90, 10), 0), isFalse); // outside once rotated
      expect(img.bounds.width, closeTo(20, 1e-9));
    });

    test('corner handles scale proportionally; Shift scales freely', () {
      final c = DrawingController();
      c.placeImage(fakePng(100, 50, 6));
      final img = c.selection.single as InkImage;
      final start = img.bounds; // 100 × 50
      c.tool = SelectionTool();
      final handle = SelectionTool.scaleHandles(start, 1)[2]; // bottom-right
      c.tool.begin(c, ToolEvent(handle, 1));
      c.tool.move(c, ToolEvent(handle + const Offset(100, 0), 1));
      c.tool.end(c, ToolEvent(handle + const Offset(100, 0), 1));
      expect(img.bounds.topLeft, start.topLeft); // anchored at the opposite corner
      expect(img.bounds.width, closeTo(200, 1e-9));
      expect(img.bounds.height, closeTo(100, 1e-9));

      final b = img.bounds;
      final h2 = SelectionTool.scaleHandles(b, 1)[2];
      c.tool.begin(c, ToolEvent(h2, 1));
      c.tool.move(c, ToolEvent(h2 + const Offset(0, 50), 1, shift: true));
      c.tool.end(c, ToolEvent(h2 + const Offset(0, 50), 1, shift: true));
      expect(img.bounds.width, closeTo(200, 1e-9));
      expect(img.bounds.height, closeTo(150, 1e-9));

      c.undo();
      c.undo();
      expect(c.drawing.activeLayer.elements.single.bounds, start);
    });

    test('scaling a shape keeps its stroke width (as in Inkpad)', () {
      final c = DrawingController();
      final p = InkPath.rect(const Rect.fromLTWH(10, 10, 10, 10))..stroke = const StrokeStyle(width: 3);
      c.addElement(p);
      c.select(p);
      c.tool = SelectionTool();
      final h = SelectionTool.scaleHandles(p.bounds, 1)[0]; // top-left
      c.tool.begin(c, ToolEvent(h, 1));
      c.tool.move(c, ToolEvent(h - const Offset(10, 10), 1));
      expect(p.bounds, const Rect.fromLTWH(0, 0, 20, 20));
      expect(p.stroke!.width, 3);
    });

    test('an image can be masked by a shape', () {
      final c = DrawingController();
      c.placeImage(fakePng(200, 200, 7));
      final img = c.selection.single;
      final circle = InkPath.oval(Rect.fromCenter(center: img.bounds.center, width: 100, height: 100));
      c.addElement(circle);
      c.selection
        ..clear()
        ..addAll([img, circle]);
      expect(c.canMakeMask, isTrue);
      c.makeMask();
      expect(c.drawing.activeLayer.elements.single, circle);
      expect(circle.maskedElements.single, img);
      expect(circle.hitTest(img.bounds.center, 0), isTrue);
      expect(circle.hitTest(img.bounds.topLeft + const Offset(5, 5), 0), isFalse); // clipped away
    });
  });

  group('storage', () {
    test('drawings carry their images once; undo snapshots skip them', () {
      final data = ImageData.register(fakePng(30, 20, 8))!;
      final d = InkDrawing()
        ..activeLayer.elements.addAll([
          InkImage(data),
          InkGroup([InkImage(data, placement: Affine.translation(50, 0))]),
        ]);
      final json = d.toJson();
      expect((json['images'] as Map).keys, [data.id]);
      expect(d.toJson(includeImages: false).containsKey('images'), isFalse);
      expect(d.encode(includeImages: false).length, lessThan(d.encode().length));

      final copy = InkDrawing.decode(d.encode());
      expect(copy.encode(), d.encode());
      expect(copy.images.single, same(data));
    });

    test('a library drawing with an image reloads', () async {
      final store = MemoryDrawingStore();
      final lib = LibraryController(store);
      await lib.load();
      final data = ImageData.register(fakePng(64, 64, 9))!;
      await lib.create(drawing: InkDrawing()..activeLayer.elements.add(InkImage(data)));
      expect(store.files.values.single, contains(base64Encode(data.bytes)));
      final reloaded = LibraryController(store);
      await reloaded.load();
      expect((reloaded.drawings.single.drawing.allElements.single as InkImage).data, same(data));
    });
  });

  group('SVG', () {
    String svg(String body) =>
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 200 200">$body</svg>';

    test('export writes each image once and round-trips exactly', () {
      final data = ImageData.register(fakePng(40, 20, 10))!;
      final d = InkDrawing(width: 200, height: 200)
        ..activeLayer.elements.addAll([
          InkImage(data, placement: Affine.translation(10, 10)),
          InkImage(data, placement: Affine.rotation(0.3).then(Affine.translation(100, 50)), opacity: 0.5),
          InkPath.oval(const Rect.fromLTWH(0, 100, 50, 50))
            ..maskedElements = [InkImage(data, placement: Affine.scale(2, 2).then(Affine.translation(0, 100)))],
        ]);
      final out = d.toSvg();
      expect(RegExp('<image ').allMatches(out).length, 1);
      expect(RegExp('<use ').allMatches(out).length, 3);
      final back = importSvg(out);
      expect(back.warnings, isEmpty);
      expect(back.drawing.toSvg(), out);
    });

    test('preserveAspectRatio: meet (default), none, slice', () {
      final uri = 'data:image/png;base64,${base64Encode(fakePng(100, 50, 11))}';
      final r = importSvg(svg('''
        <image x="0" y="0" width="100" height="100" href="$uri"/>
        <image x="0" y="0" width="100" height="100" preserveAspectRatio="none" xlink:href="$uri"/>
        <image x="0" y="0" width="100" height="100" preserveAspectRatio="xMinYMax slice" href="$uri"/>
        <image x="10" y="20" href="$uri"/>
      '''));
      final els = r.drawing.allElements.toList();
      expect(els[0].bounds, const Rect.fromLTWH(0, 25, 100, 50)); // centered, fits the width
      expect(els[1].bounds, const Rect.fromLTWH(0, 0, 100, 100)); // stretched
      final crop = els[2] as InkPath; // slice = fill the box, cropped by a mask
      expect(crop.bounds, const Rect.fromLTWH(0, 0, 100, 100));
      expect(crop.maskedElements.single.bounds, const Rect.fromLTWH(0, 0, 200, 100)); // aligned left
      expect(els[3].bounds, const Rect.fromLTWH(10, 20, 100, 50)); // natural size
      expect(r.warnings, isEmpty);
    });

    test('linked, unreadable and unsupported images are reported', () {
      final r = importSvg(svg('''
        <image width="10" height="10" href="photo.jpg"/>
        <image width="10" height="10" href="data:image/png;base64,%%%"/>
        <image width="10" height="10" href="data:image/png;base64,${base64Encode(utf8.encode('nope'))}"/>
        <image width="10" height="10" href="data:image/svg+xml,%3Csvg/%3E"/>
      '''));
      expect(r.drawing.allElements, isEmpty);
      expect(r.warnings, containsAll([
        'Linked images (not embedded in the file) were skipped',
        'Skipped 1 unreadable image',
        'Skipped 1 image in an unsupported format',
        'Skipped 1 embedded SVG image',
      ]));
    });
  });

  testWidgets('placed images decode and draw', (tester) async {
    final bytes = await realPng(tester, 8, 4);
    final data = ImageData.register(bytes)!;
    expect((data.width, data.height), (8, 4));
    expect(data.decoded, isNull); // decoding starts on first use
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && data.decoded == null && !data.decodeFailed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(data.decodeFailed, isFalse);
    expect(data.decoded!.width, 8);
  });
}
