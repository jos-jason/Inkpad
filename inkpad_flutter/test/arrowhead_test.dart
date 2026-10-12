import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/geometry/arrowheads.dart';
import 'package:inkpad/geometry/pathfinder.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/svg/svg_importer.dart';

InkPath line({String start = '', String end = '', double width = 2, LineCap cap = LineCap.round, double length = 100}) => InkPath(
      nodes: [const BezierNode.anchor(Offset(0, 50)), BezierNode.anchor(Offset(length, 50))],
      stroke: StrokeStyle(width: width, cap: cap, startArrow: start, endArrow: end),
    );

void main() {
  test('every arrowhead is built, inside its box', () {
    for (final id in Arrowhead.ids) {
      final a = Arrowhead.named(id)!;
      expect(a.contours, isNotEmpty, reason: id);
      expect(a.bounds.topLeft, Offset.zero, reason: id);
      expect(a.bounds.width, inInclusiveRange(1, id.startsWith("chubby") ? 10 : 7.2), reason: id);
      expect(a.bounds.height, inInclusiveRange(5.5, id.startsWith("chubby") ? 10.5 : 7.6), reason: id);
      expect(a.insetLength(false), greaterThan(0), reason: id);
    }
    expect(Arrowhead.named(''), isNull);
    expect(Arrowhead.named('nope'), isNull);
    expect(Arrowhead.named('arrow1')!.insetLength(false), 3.5);
    // Butt caps move the attachment so the line's square end is covered.
    expect(Arrowhead.named('open circle')!.insetLength(true), Arrowhead.named('open circle')!.insetLength(false) - 0.25);
  });

  test('the line is trimmed back and the arrow tips sit on the path ends', () {
    final p = line(start: 'closed circle', end: 'arrow1');
    final a = p.arrowLayout!;
    expect(a.line.first.anchorPoint.dx, closeTo(Arrowhead.named('closed circle')!.insetLength(false) * 2, 1e-6));
    expect(a.line.last.anchorPoint.dx, closeTo(100 - 3.5 * 2, 1e-6));
    final heads = a.arrowOutlines(p.stroke!).map((c) => c.bounds).reduce((x, y) => x.expandToInclude(y));
    expect(heads.left, closeTo(0, 1e-6));
    expect(heads.right, closeTo(100, 1e-6));
    expect(heads.center.dy, closeTo(50, 1e-6));
    // The arrows count toward what's painted and what can be clicked.
    expect(p.styleBounds.top, lessThan(50 - 6));
    expect(p.hitTest(const Offset(95, 52), 0), isTrue);
  });

  test('on a curve the arrow attaches at the right distance and points along it', () {
    final p = InkPath(
      nodes: [
        const BezierNode(Offset(0, 0), Offset(0, 0), Offset(50, 0)),
        const BezierNode(Offset(100, 50), Offset(100, 100), Offset(100, 100)),
      ],
      stroke: const StrokeStyle(width: 4, endArrow: 'arrow2'),
    );
    final a = p.arrowLayout!;
    final attach = a.endAt!.$1;
    expect((attach - const Offset(100, 100)).distance, closeTo(Arrowhead.named('arrow2')!.insetLength(false) * 4, 1e-3));
    expect(a.endAt!.$2, closeTo(1.5708, 0.2)); // pointing down, along the curve's end
  });

  test('no arrows when the path is too short for them', () {
    expect(line(end: 'arrow1', width: 20, length: 30).arrowLayout, isNull);
    expect(line().arrowLayout, isNull);
  });

  test('JSON keeps the arrows; reversing keeps them at the same ends', () {
    final p = line(start: 'T shape', end: 'open diamond');
    final copy = InkElement.fromJson(p.toJson()) as InkPath;
    expect((copy.stroke!.startArrow, copy.stroke!.endArrow), ('T shape', 'open diamond'));
    expect(StrokeStyle.fromJson(const StrokeStyle().toJson()).hasArrows, isFalse);

    final c = DrawingController();
    c.addElement(p);
    c.select(p);
    c.reversePaths();
    expect((p.stroke!.startArrow, p.stroke!.endArrow), ('open diamond', 'T shape'));
    expect(p.nodes.first.anchorPoint, const Offset(100, 50));
  });

  test('SVG export draws trimmed line and arrows, and imports back as one path', () {
    final p = line(start: 'open circle', end: 'arrow3', width: 3)
      ..stroke = line(start: 'open circle', end: 'arrow3', width: 3).stroke!.copyWith(color: const InkColor(1, 0, 0, 0.5))
      ..fill = const InkColor(0, 0, 1);
    final svg = (InkDrawing()..activeLayer.elements.add(p)).toSvg();
    expect(svg, contains('inkpad:start-arrow="open circle"'));
    expect(svg, contains('inkpad:end-arrow="arrow3"'));
    expect(svg, contains('<g opacity="0.5">'));
    final back = importSvg(svg).drawing.allElements.single as InkPath;
    expect(back.svgPathData, p.svgPathData);
    expect(back.fill, const InkColor(0, 0, 1));
    expect((back.stroke!.startArrow, back.stroke!.endArrow, back.stroke!.width), ('open circle', 'arrow3', 3));
    expect(back.stroke!.color.alpha, closeTo(0.5, 1e-6));
  });

  test('outline stroke includes the arrowheads', () {
    final o = Pathfinder.outlineStroke(line(end: 'closed square', width: 4))!;
    expect(o.bounds.right, closeTo(100, 0.2));
    expect(o.bounds.height, closeTo(6 * 4, 0.5)); // the square is 6 wide, times the width
  });

  test('a see-through stroke and its arrow are one even color', () async {
    final p = line(end: 'arrow2', width: 6, cap: LineCap.butt)..stroke = line(end: 'arrow2', width: 6, cap: LineCap.butt).stroke!.copyWith(color: const InkColor(0, 0, 0, 0.5));
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 120, 100), Paint()..color = const Color(0xFFFFFFFF));
    p.render(canvas);
    final img = await rec.endRecording().toImage(120, 100);
    final d = (await img.toByteData())!;
    int at(int x, int y) => d.getUint8((y * 120 + x) * 4);
    final attachX = p.arrowLayout!.endAt!.$1.dx.round();
    expect(at(attachX, 50), closeTo(at(50, 50), 2)); // overlap of line and arrow
    expect(at(attachX + 4, 50), closeTo(at(50, 50), 2)); // arrow only
    expect(at(50, 50), inInclusiveRange(120, 135)); // half black on white
  });
}
