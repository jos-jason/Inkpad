import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/geometry.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/svg/svg_importer.dart';
import 'package:inkpad/svg/svg_path_parser.dart';
import 'package:inkpad/svg/svg_values.dart';

String svg(String body, {String attrs = 'viewBox="0 0 100 100"'}) =>
    '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" $attrs>$body</svg>';

/// All drawable (non-group) elements in document order.
List<InkStylable> shapes(InkDrawing d) {
  final out = <InkStylable>[];
  void walk(InkElement e) => e is InkGroup ? e.elements.forEach(walk) : out.add(e as InkStylable);
  d.allElements.forEach(walk);
  return out;
}

Matcher near(Rect r, [double tol = 0.01]) => predicate<Rect>(
      (a) =>
          (a.left - r.left).abs() < tol &&
          (a.top - r.top).abs() < tol &&
          (a.right - r.right).abs() < tol &&
          (a.bottom - r.bottom).abs() < tol,
      'near $r',
    );

void main() {
  group('path data', () {
    test('absolute and relative lines, H/V, implicit lineto', () {
      final p = parseSvgPathData('M10 10 20 10 l0 10 H10 v-10').single;
      expect(p.nodes.map((n) => n.anchorPoint).toList(), const [
        Offset(10, 10), Offset(20, 10), Offset(20, 20), Offset(10, 20), Offset(10, 10),
      ]);
      expect(p.closed, isFalse);
    });

    test('Z merges an explicit return to the start', () {
      final p = parseSvgPathData('M0 0L10 0L10 10L0 0Z').single;
      expect(p.closed, isTrue);
      expect(p.nodes.length, 3);
    });

    test('compact number syntax', () {
      final p = parseSvgPathData('M10-5L.5.5-1e1,2').single;
      expect(p.nodes.map((n) => n.anchorPoint).toList(), const [Offset(10, -5), Offset(.5, .5), Offset(-10, 2)]);
    });

    test('multiple subpaths, and drawing after Z starts at the old start', () {
      final ps = parseSvgPathData('M0 0h10v10z l5 5 h5 M50 50 h1');
      expect(ps.length, 3);
      expect(ps[1].nodes.first.anchorPoint, Offset.zero);
      expect(ps[1].nodes.last.anchorPoint, const Offset(10, 5));
    });

    test('S reflects the previous control point; Q/T become cubics', () {
      final s = parseSvgPathData('M0 0 C0 10 10 10 10 0 S20 -10 20 0').single;
      expect(s.nodes[1].outPoint, const Offset(10, -10));
      final q = parseSvgPathData('M0 0 Q5 10 10 0 T20 0').single;
      // Quadratic peak at t=0.5 is halfway to the control point.
      expect(q.segments.first.pointAt(0.5).dy, closeTo(5, 1e-9));
      expect(q.segments.last.pointAt(0.5).dy, closeTo(-5, 1e-9));
    });

    test('arcs: two half circles make a circle', () {
      final p = parseSvgPathData('M0 50 A50 50 0 0 1 100 50 A50 50 0 0 1 0 50Z').single;
      expect(p.bounds, near(const Rect.fromLTWH(0, 0, 100, 100), 0.1));
      // A point at 45° lies on the circle.
      final mid = p.segments.first.pointAt(0.5);
      expect((mid - const Offset(50, 50)).distance, closeTo(50, 0.1));
    });

    test('arc flags without separators; radii scaled up when too small', () {
      final p = parseSvgPathData('M0 0a1 1 0 01 10 0').single;
      expect(p.nodes.last.anchorPoint.dx, closeTo(10, 1e-9));
      expect(p.bounds.top, closeTo(-5, 0.05)); // sweep=1 goes upwards in y-down space
    });

    test('malformed data keeps what parsed', () {
      final ps = parseSvgPathData('M0 0 L10 10 L oops');
      expect(ps.single.nodes.length, 2);
    });
  });

  group('values', () {
    test('colors', () {
      expect(parseColor('#f80'), const InkColor(1, 0x88 / 255, 0));
      expect(parseColor('rebeccapurple')!.hexValue, '#663399');
      expect(parseColor('rgb(255, 0, 0)'), const InkColor(1, 0, 0));
      expect(parseColor('rgb(100%,50%,0%)'), const InkColor(1, 0.5, 0));
      expect(parseColor('rgba(0,0,255,.5)')!.alpha, 0.5);
      expect(parseColor('#00ff0080')!.alpha, closeTo(0.5, 0.01));
      expect(parseColor('hsl(120, 100%, 50%)')!.hexValue, '#00ff00');
      expect(parseColor('nonsense'), isNull);
    });

    test('lengths', () {
      expect(parseLength('10'), 10);
      expect(parseLength('1in'), 96);
      expect(parseLength('25.4mm'), closeTo(96, 1e-9));
      expect(parseLength('50%', percentOf: 300), 150);
      expect(parseLength('50%'), isNull);
    });

    test('transforms compose right-to-left', () {
      final t = parseTransform('translate(10,0) scale(2)');
      expect(t.apply(const Offset(1, 1)), const Offset(12, 2));
      final r = parseTransform('rotate(90 10 10)');
      final p = r.apply(const Offset(20, 10));
      expect(p.dx, closeTo(10, 1e-9));
      expect(p.dy, closeTo(20, 1e-9));
    });
  });

  group('importSvg', () {
    test('basic shapes, sizes and default styles', () {
      final r = importSvg(svg('''
        <rect x="10" y="10" width="20" height="10"/>
        <rect x="0" y="50" width="40" height="20" rx="5"/>
        <circle cx="50" cy="50" r="10" fill="red"/>
        <ellipse cx="80" cy="20" rx="10" ry="5"/>
        <line x1="0" y1="0" x2="100" y2="100" stroke="blue" stroke-width="3"/>
        <polygon points="0,0 10,0 5,10"/>
        <polyline points="0 0 10 10 20 0" fill="none" stroke="black"/>
      '''));
      final s = shapes(r.drawing);
      expect(r.drawing.width, 100);
      expect(s.length, 7);
      expect(s[0].bounds, near(const Rect.fromLTWH(10, 10, 20, 10)));
      expect(s[0].fill, InkColor.black); // SVG default fill
      expect(s[0].stroke, isNull);
      expect(s[1].bounds, near(const Rect.fromLTWH(0, 50, 40, 20)));
      expect((s[1] as InkPath).nodes.length, 8);
      expect(s[2].fill, const InkColor(1, 0, 0));
      expect(s[4].fill, isNull); // lines never fill
      expect(s[4].stroke!.width, 3);
      expect(s[4].stroke!.cap, LineCap.butt); // SVG default
      expect((s[5] as InkPath).closed, isTrue);
      expect((s[6] as InkPath).closed, isFalse);
      expect(r.warnings, isEmpty);
    });

    test('viewBox offset and transforms are baked in; stroke scales', () {
      final r = importSvg(svg(
        '<g transform="scale(2)"><rect x="60" y="60" width="10" height="10" stroke="black" stroke-width="1"/></g>',
        attrs: 'viewBox="50 50 100 100" width="400" height="400"',
      ));
      final s = shapes(r.drawing).single;
      expect(r.drawing.width, 100); // viewBox size wins
      expect(s.bounds, near(const Rect.fromLTWH(70, 70, 20, 20)));
      expect(s.stroke!.width, 2);
    });

    test('no viewBox: width/height with units, or content size', () {
      expect(importSvg(svg('<rect width="1" height="1"/>', attrs: 'width="1in" height="2in"')).drawing.height, 192);
      final r = importSvg(svg('<rect x="10" y="10" width="290" height="140"/>', attrs: ''));
      expect(r.drawing.width, 300);
      expect(r.drawing.height, 150);
    });

    test('styles: attributes < CSS (by specificity) < style attribute, with inheritance', () {
      final r = importSvg(svg('''
        <style>
          rect { fill: green }
          .a { fill: #0000ff; stroke: red }
          #special { fill: yellow }
          .b, .c { stroke-width: 4 }
        </style>
        <g fill="purple" stroke-width="2">
          <circle r="1" cx="5" cy="5"/>
          <rect width="1" height="1" fill="orange"/>
          <rect width="1" height="1" class="a b"/>
          <rect width="1" height="1" class="a" id="special" style="stroke: lime"/>
        </g>
      '''));
      final s = shapes(r.drawing);
      expect((s[0].fill as InkColor).hexValue, '#800080'); // inherited from <g>
      expect((s[1].fill as InkColor).hexValue, '#008000'); // CSS beats presentation attribute
      expect((s[2].fill as InkColor).hexValue, '#0000ff');
      expect(s[2].stroke!.width, 4);
      expect((s[3].fill as InkColor).hexValue, '#ffff00'); // id beats class
      expect(s[3].stroke!.color.hexValue, '#00ff00'); // style="" beats CSS
      expect(s[3].stroke!.width, 2); // inherited
    });

    test('CSS descendant and child selectors', () {
      final r = importSvg(svg('''
        <style>
          g.icons rect { fill: red }
          g.icons > circle { fill: blue }
          svg circle { stroke: black }
          .nope > rect, :hover { fill: green }
        </style>
        <g class="icons"><g><rect width="1" height="1"/><circle r="1"/></g><circle r="2"/></g>
      '''));
      final s = shapes(r.drawing);
      expect((s[0].fill as InkColor).hexValue, '#ff0000');
      expect((s[1].fill as InkColor).hexValue, '#000000'); // nested deeper: `>` doesn't match
      expect(s[1].stroke, isNotNull);
      expect((s[2].fill as InkColor).hexValue, '#0000ff');
      expect(r.warnings.single, contains('CSS selectors'));
    });

    test('opacity, fill-opacity, currentColor, display none, dashes', () {
      final r = importSvg(svg('''
        <g color="red" opacity="0.5">
          <rect width="1" height="1" fill="currentColor" fill-opacity="0.5" opacity="0.5"/>
          <rect width="1" height="1"/>
        </g>
        <rect width="1" height="1" display="none"/>
        <g style="display:none"><rect width="1" height="1"/></g>
        <path d="M0 0H10" stroke="black" stroke-dasharray="1 2 3"/>
      '''));
      final group = r.drawing.allElements.first as InkGroup;
      expect(group.opacity, 0.5);
      final first = group.elements.first as InkPath;
      expect(first.fill, const InkColor(1, 0, 0, 0.5));
      expect(first.opacity, 0.5);
      expect(r.drawing.allElements.length, 2);
      expect(shapes(r.drawing).last.stroke!.dashPattern, [1, 2, 3, 1, 2, 3]);
    });

    test('a path with several subpaths becomes a compound path with holes', () {
      final r = importSvg(svg(
          '<path fill-rule="evenodd" d="M0 0H100V100H0Z M25 25H75V75H25Z"/>'));
      final ring = r.drawing.allElements.single as InkCompoundPath;
      expect(ring.subpaths.length, 2);
      expect(ring.hitTest(const Offset(10, 10), 0), isTrue);
      expect(ring.hitTest(const Offset(50, 50), 0), isFalse); // the hole
    });

    test('top-level groups with ids become layers (Inkpad and Inkscape)', () {
      final r = importSvg(svg('''
        <rect width="1" height="1"/>
        <g id="Background" opacity="0.5"><rect width="1" height="1"/><rect width="2" height="2"/></g>
        <g xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
           inkscape:groupmode="layer" inkscape:label="Ink layer" style="display:none">
          <circle r="1"/>
        </g>
        <circle r="2"/>
      '''));
      final layers = r.drawing.layers;
      expect(layers.map((l) => l.name).toList(), ['Layer 1', 'Background', 'Ink layer', 'Layer 4']);
      expect(layers[1].opacity, 0.5);
      expect(layers[1].elements.length, 2);
      expect(layers[2].visible, isFalse);
      expect(r.drawing.activeLayerIndex, 3);
    });

    test('groups: single children are unwrapped', () {
      final r = importSvg(svg('<g><g><rect width="1" height="1"/></g></g><g><circle r="1"/><circle r="2"/></g>'));
      expect(r.drawing.allElements.first, isA<InkPath>());
      expect(r.drawing.allElements.last, isA<InkGroup>());
    });

    test('use, symbol, and xlink:href', () {
      final r = importSvg(svg('''
        <defs><rect id="box" width="10" height="10"/></defs>
        <symbol id="pair"><circle r="1"/><circle cx="5" r="1"/></symbol>
        <use xlink:href="#box" x="20" fill="red"/>
        <use href="#pair" y="50"/>
        <use href="#missing"/>
      '''));
      final s = shapes(r.drawing);
      expect(s.length, 3);
      expect(s[0].bounds, near(const Rect.fromLTWH(20, 0, 10, 10)));
      expect(s[0].fill, const InkColor(1, 0, 0)); // inherited from <use>
      expect(s[1].bounds.center.dy, closeTo(50, 1e-6));
      expect(r.warnings.single, contains('missing'));
    });

    test('linear gradients: bounding-box units, href inheritance, stop rules', () {
      final r = importSvg(svg('''
        <defs>
          <linearGradient id="base" x2="0" y2="1">
            <stop offset="0" stop-color="#000"/><stop offset="50%" style="stop-color:#fff;stop-opacity:.5"/>
            <stop offset="0.2" stop-color="red"/>
          </linearGradient>
          <linearGradient id="g" xlink:href="#base" spreadMethod="reflect"/>
        </defs>
        <rect x="10" y="20" width="40" height="80" fill="url(#g)" fill-opacity="0.5"/>
        <rect width="10" height="10" fill="url(#nothing) blue"/>
        <text>Hi</text><text>There</text>
        <image href="x.png"/>
      '''));
      final s = shapes(r.drawing);
      final g = s[0].fill as InkGradient;
      expect(g.type, GradientType.linear);
      expect(g.spread, SpreadMethod.reflect);
      expect(g.stops.map((s) => s.offset), [0, 0.5, 0.5]); // offsets never go backwards
      expect(g.stops[0].color.alpha, 0.5); // fill-opacity
      expect(g.stops[1].color.alpha, 0.25); // stop-opacity × fill-opacity
      // x2=0 y2=1 in box units: top to bottom of the rect.
      final geom = g.geometry!;
      expect(geom.documentStart, const Offset(10, 20));
      expect(geom.documentEnd, const Offset(10, 100));
      expect(s[1].fill, const InkColor(0, 0, 1));
      expect(r.warnings, containsAll(['Skipped 2 text elements', 'Skipped 1 image']));
      expect(r.warnings.any((w) => w.contains('radient')), isFalse);
    });

    test('radial gradients: user space, focal point, gradientTransform, element transform', () {
      final r = importSvg(svg('''
        <radialGradient id="r" gradientUnits="userSpaceOnUse" cx="50" cy="50" r="20" fx="40" fy="50"
            gradientTransform="scale(1 0.5)">
          <stop offset="0" stop-color="white"/><stop offset="1" stop-color="black"/>
        </radialGradient>
        <g transform="translate(100 0)"><circle cx="50" cy="25" r="20" fill="url(#r)"/></g>
      ''', attrs: 'viewBox="0 0 200 100"'));
      final g = shapes(r.drawing).single.fill as InkGradient;
      expect(g.type, GradientType.radial);
      final geom = g.geometry!;
      expect(geom.start, const Offset(50, 50));
      expect(geom.focal, const Offset(40, 50));
      expect(geom.documentStart, const Offset(150, 25)); // scaled, then translated
      expect(geom.documentEnd, const Offset(170, 25));
    });

    test('degenerate gradients fall back to a color', () {
      final r = importSvg(svg('''
        <linearGradient id="one"><stop offset="0" stop-color="red"/></linearGradient>
        <linearGradient id="two"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient>
        <radialGradient id="zero" r="0"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="lime"/></radialGradient>
        <rect width="10" height="10" fill="url(#one)"/>
        <path d="M0 0H10" stroke="black" fill="url(#two)"/>
        <rect width="10" height="10" fill="url(#zero)"/>
      '''));
      final s = shapes(r.drawing);
      expect(s[0].fill, const InkColor(1, 0, 0));
      expect(s[1].fill, isA<InkColor>()); // flat shape: no bounding box
      expect(s[2].fill, const InkColor(0, 1, 0));
    });

    test('gradient outlines become a solid color, with a note', () {
      final r = importSvg(svg('''
        <linearGradient id="g"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
        <rect width="10" height="10" fill="none" stroke="url(#g)"/>
      '''));
      expect(shapes(r.drawing).single.stroke!.color.red, closeTo(0.5, 1e-9));
      expect(r.warnings.single, contains('Gradient outlines'));
    });

    test('clip paths become clipping masks', () {
      final r = importSvg(svg('''
        <clipPath id="c"><circle cx="50" cy="50" r="40"/></clipPath>
        <clipPath id="box" clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>
        <clipPath id="empty"></clipPath>
        <g clip-path="url(#c)" opacity="0.5"><rect width="100" height="100" fill="red"/><rect width="10" height="10"/></g>
        <rect x="0" y="0" width="40" height="20" clip-path="url(#box)" fill="blue"/>
        <rect width="10" height="10" style="clip-path:url(#empty)"/>
      '''));
      final els = r.drawing.allElements.toList();
      expect(els.length, 2); // an empty clip path hides its element
      final mask = els[0] as InkPath;
      expect(mask.fill, isNull);
      expect(mask.stroke, isNull);
      expect(mask.opacity, 0.5);
      expect(mask.maskedElements.length, 2); // the group's children
      expect(mask.bounds, near(const Rect.fromLTWH(10, 10, 80, 80)));
      expect(mask.hitTest(const Offset(50, 50), 0), isTrue);
      expect(mask.hitTest(const Offset(2, 2), 0), isFalse); // clipped away
      final half = els[1] as InkPath;
      expect(half.bounds, near(const Rect.fromLTWH(0, 0, 20, 20)));
      expect(r.warnings, isEmpty);
    });

    test('solid white masks act as clips; soft masks become even transparency', () {
      final r = importSvg(svg('''
        <mask id="m"><rect x="10" y="10" width="30" height="30" fill="#fff"/></mask>
        <mask id="soft"><rect width="50" height="50" fill="white" opacity="0.5"/></mask>
        <linearGradient id="fade"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>
        <mask id="fader"><rect width="50" height="50" fill="url(#fade)"/></mask>
        <rect width="100" height="100" mask="url(#m)"/>
        <rect width="100" height="100" mask="url(#soft)"/>
        <rect width="100" height="100" mask="url(#fader)"/>
      '''));
      final els = r.drawing.allElements.cast<InkStylable>().toList();
      expect(els[0].isMasking, isTrue);
      expect(els[0].opacity, 1);
      expect(els[0].bounds, near(const Rect.fromLTWH(10, 10, 30, 30)));
      expect(els[1].isMasking, isTrue);
      expect(els[1].opacity, closeTo(0.5, 1e-9));
      expect(els[1].bounds, near(const Rect.fromLTWH(0, 0, 50, 50)));
      expect(els[2].opacity, closeTo(0.5, 1e-9)); // white→black averages to half
      expect(r.warnings.single, contains('Soft masks'));
    });

    test('round-trips our own SVG export', () {
      final d = InkDrawing(width: 300, height: 200);
      d.activeLayer.elements.addAll([
        InkPath.oval(const Rect.fromLTWH(10, 10, 100, 50))
          ..fill = const InkColor(1, 0, 0, 0.5)
          ..stroke = const StrokeStyle(width: 3, dashPattern: [4, 2]),
        InkGroup([
          InkPath.rect(const Rect.fromLTWH(0, 0, 20, 20))..fill = InkColor.black,
          InkPath.star(const Rect.fromLTWH(50, 50, 40, 40), 5)..stroke = const StrokeStyle(),
        ], opacity: 0.7),
        InkCompoundPath(
          [InkPath.rect(const Rect.fromLTWH(0, 0, 50, 50)), InkPath.rect(const Rect.fromLTWH(10, 10, 20, 20))],
          fill: InkColor.white,
          fillRule: FillRule.evenOdd,
        ),
      ]);
      d.activeLayer.elements.addAll([
        InkPath.rect(const Rect.fromLTWH(0, 100, 80, 40))
          ..fill = InkGradient.between(InkColor.black, const InkColor(1, 1, 1, 0.5)),
        InkPath.oval(const Rect.fromLTWH(100, 100, 60, 60))
          ..fill = const InkGradient(
            type: GradientType.radial,
            spread: SpreadMethod.repeat,
            stops: [GradientStop(0, InkColor.white), GradientStop(0.3, InkColor.black), GradientStop(1, InkColor.white)],
            geometry: GradientGeometry(Offset(0, 0), Offset(1, 0), focal: Offset(0.2, 0),
                transform: Affine(30, 0, 0, 15, 130, 130)),
          ),
        InkPath.oval(const Rect.fromLTWH(200, 100, 50, 50))
          ..maskedElements = [
            InkPath.rect(const Rect.fromLTWH(190, 90, 70, 70))..fill = InkColor.black,
            InkPath.star(const Rect.fromLTWH(200, 100, 50, 50), 5)..fill = InkColor.white,
          ],
      ]);
      d.addLayer();
      d.activeLayer
        ..visible = false
        ..opacity = 0.25
        ..elements.add(InkPath.rect(const Rect.fromLTWH(1, 2, 3, 4))..fill = InkColor.black);

      final exported = d.toSvg();
      final imported = importSvg(exported);
      expect(imported.warnings, isEmpty);
      expect(imported.drawing.toSvg(), exported);
    });

    test('rejects files that are not SVG', () {
      expect(() => importSvg('not xml at all'), throwsA(isA<SvgImportException>()));
      expect(() => importSvg('<html><body/></html>'), throwsA(isA<SvgImportException>()));
    });
  });
}
