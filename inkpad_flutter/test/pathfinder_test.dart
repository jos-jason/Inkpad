import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/geometry/curve_fit.dart';
import 'package:inkpad/geometry/pathfinder.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';

bool smooth(InkPath p) => p.nodes.any((n) => n.hasInPoint || n.hasOutPoint);

/// Fraction of [samples] points (inside [area]) where the shape's fill
/// contains the point, compared against [expected].
void expectCoverage(InkStylable shape, bool Function(Offset) expected, Rect area) {
  final path = shape.toFlutterPath();
  var mismatches = 0, total = 0;
  for (var x = area.left + 0.5; x < area.right; x += 1) {
    for (var y = area.top + 0.5; y < area.bottom; y += 1) {
      final p = Offset(x, y);
      total++;
      if (path.contains(p) != expected(p)) mismatches++;
    }
  }
  // Allow for edge pixels only.
  expect(mismatches / total, lessThan(0.02), reason: '$mismatches of $total sample points differ');
}

bool inCircle(Offset p, Offset c, double r) => (p - c).distance <= r;

void main() {
  test('curve fitting reproduces a circle with few nodes', () {
    final pts = [for (var i = 0; i < 200; i++) Offset(50 + 40 * math.cos(i / 200 * 2 * math.pi), 50 + 40 * math.sin(i / 200 * 2 * math.pi))];
    final nodes = fitNodes(pts, closed: true, isCorner: (_) => false);
    expect(nodes.length, lessThanOrEqualTo(8));
    final path = InkPath(nodes: nodes, closed: true);
    for (final s in path.segments) {
      for (var t = 0.0; t <= 1; t += 0.1) {
        expect((s.pointAt(t) - const Offset(50, 50)).distance, closeTo(40, 0.2));
      }
    }
  });

  test('unite two overlapping rectangles: 8 sharp corners, straight edges', () {
    final a = InkPath.rect(const Rect.fromLTWH(0, 0, 20, 20));
    final b = InkPath.rect(const Rect.fromLTWH(10, 10, 20, 20));
    final r = Pathfinder.combine([a, b], BooleanOp.unite) as InkPath;
    expect(r.nodes.length, 8);
    expect(smooth(r), isFalse);
    expect(r.bounds, const Rect.fromLTWH(0, 0, 30, 30));
  });

  test('unite two circles: smooth arcs, sharp where they cross', () {
    final a = InkPath.oval(Rect.fromCircle(center: const Offset(30, 30), radius: 20));
    final b = InkPath.oval(Rect.fromCircle(center: const Offset(55, 30), radius: 20));
    final r = Pathfinder.combine([a, b], BooleanOp.unite) as InkPath;
    expect(r.nodes.length, lessThanOrEqualTo(14));
    expect(r.nodes.where((n) => n.isCorner).length, 2); // the two crossing points
    expectCoverage(r, (p) => inCircle(p, const Offset(30, 30), 20) || inCircle(p, const Offset(55, 30), 20),
        const Rect.fromLTWH(0, 0, 90, 60));
  });

  test('intersect, subtract front, exclude', () {
    final a = InkPath.rect(const Rect.fromLTWH(0, 0, 40, 40));
    final b = InkPath.oval(Rect.fromCircle(center: const Offset(20, 20), radius: 10));
    final c = InkPath.oval(Rect.fromCircle(center: const Offset(40, 40), radius: 15));

    final i = Pathfinder.combine([a, c], BooleanOp.intersect)!;
    expectCoverage(i, (p) => p.dx <= 40 && p.dy <= 40 && inCircle(p, const Offset(40, 40), 15), const Rect.fromLTWH(0, 0, 60, 60));

    final hole = Pathfinder.combine([a, b], BooleanOp.subtractFront)!;
    expect(hole, isA<InkCompoundPath>()); // a square with a round hole
    expect(hole.toFlutterPath().contains(const Offset(20, 20)), isFalse);
    expect(hole.toFlutterPath().contains(const Offset(3, 3)), isTrue);

    final x = Pathfinder.combine([a, c], BooleanOp.exclude)!;
    expectCoverage(x, (p) => (p.dx <= 40 && p.dy <= 40) != inCircle(p, const Offset(40, 40), 15), const Rect.fromLTWH(0, 0, 60, 60));

    // Nothing left.
    expect(Pathfinder.combine([b, InkPath.rect(const Rect.fromLTWH(100, 100, 5, 5))], BooleanOp.intersect), isNull);
  });

  test('even-odd shapes keep their holes', () {
    final ring = InkCompoundPath([
      InkPath.rect(const Rect.fromLTWH(0, 0, 30, 30)),
      InkPath.rect(const Rect.fromLTWH(10, 10, 10, 10)),
    ], fillRule: FillRule.evenOdd);
    final r = Pathfinder.combine([ring, InkPath.rect(const Rect.fromLTWH(25, 0, 20, 5))], BooleanOp.unite)!;
    expect(r.toFlutterPath().contains(const Offset(15, 15)), isFalse);
    expect(r.toFlutterPath().contains(const Offset(40, 2)), isTrue);
  });

  test('outline stroke: line, closed square with miter joins, round caps, dashes', () {
    final line = InkPath(nodes: [const BezierNode.anchor(Offset(0, 0)), const BezierNode.anchor(Offset(100, 0))])
      ..stroke = const StrokeStyle(width: 10, cap: LineCap.butt);
    final o = Pathfinder.outlineStroke(line) as InkPath;
    expect(o.nodes.length, 4);
    expect(o.bounds, const Rect.fromLTRB(0, -5, 100, 5));

    final square = InkPath.rect(const Rect.fromLTWH(0, 0, 50, 50))..stroke = const StrokeStyle(width: 4, join: LineJoin.miter);
    final frame = Pathfinder.outlineStroke(square)!;
    expect(frame, isA<InkCompoundPath>());
    expect(frame.bounds, const Rect.fromLTRB(-2, -2, 52, 52));
    expect(frame.toFlutterPath().contains(const Offset(25, 25)), isFalse);

    final round = InkPath(nodes: [const BezierNode.anchor(Offset(0, 0)), const BezierNode.anchor(Offset(50, 0))])
      ..stroke = const StrokeStyle(width: 10, cap: LineCap.round);
    final r = Pathfinder.outlineStroke(round) as InkPath;
    // The cap's leftmost point on the curve (bounds would include handles).
    final minX = [for (final seg in r.segments) for (var t = 0.0; t <= 1; t += 0.02) seg.pointAt(t).dx].reduce(math.min);
    expect(minX, closeTo(-5, 0.1));
    expect(smooth(r), isTrue);
    expect(r.nodes.length, lessThan(14));

    final dashed = InkPath(nodes: [const BezierNode.anchor(Offset(0, 0)), const BezierNode.anchor(Offset(100, 0))])
      ..stroke = const StrokeStyle(width: 2, cap: LineCap.butt, dashPattern: [10, 10]);
    expect((Pathfinder.outlineStroke(dashed) as InkCompoundPath).subpaths.length, 5);

    expect(Pathfinder.outlineStroke(InkPath.rect(const Rect.fromLTWH(0, 0, 5, 5))), isNull); // no stroke
  });

  test('add anchors halves every segment without changing the shape', () {
    final p = InkPath.oval(const Rect.fromLTWH(0, 0, 100, 50));
    final before = p.toFlutterPath().getBounds();
    addAnchorsToPath(p);
    expect(p.nodes.length, 8);
    expect(p.toFlutterPath().getBounds(), before);
  });

  test('outlining a straight round-capped line keeps it straight', () {
    for (final cap in LineCap.values) {
      final line = InkPath(
        nodes: [const BezierNode.anchor(Offset(10, 120)), const BezierNode.anchor(Offset(150, 120))],
        stroke: StrokeStyle(width: 4, cap: cap),
      );
      final o = Pathfinder.outlineStroke(line)!;
      // Every point on the outline stays within the stroke's reach.
      for (final seg in (o as InkPath).segments) {
        for (var t = 0.0; t <= 1; t += 0.05) {
          expect((seg.pointAt(t).dy - 120).abs(), lessThan(2.2), reason: '$cap');
        }
      }
    }
  });
}

