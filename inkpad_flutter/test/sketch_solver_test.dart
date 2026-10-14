import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/geometry/sketch_solver.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/constraints.dart';
import 'package:inkpad/model/element.dart';

InkPath rect(String id, Rect r) => InkPath.live(LiveShape.inRect(LiveKind.rectangle, r))..id = id;
InkPath line(String id, Offset a, Offset b) => InkPath.live(LiveShape.line(a, b))..id = id;
InkPath circle(String id, Offset c, double r) =>
    InkPath.live(LiveShape.inRect(LiveKind.ellipse, Rect.fromCircle(center: c, radius: r)))..id = id;

GeoRef pt(String e, int i) => GeoRef(e, GeoKind.point, i);
GeoRef ln(String e, int i) => GeoRef(e, GeoKind.line, i);
GeoRef ci(String e) => GeoRef(e, GeoKind.circle, 0);

Map<String, InkElement> byId(List<InkElement> es) => {for (final e in es) e.id!: e};

void main() {
  test('coincident corners and a distance', () {
    final a = rect('a', const Rect.fromLTWH(0, 0, 100, 50)), b = rect('b', const Rect.fromLTWH(130, 20, 40, 40));
    final cs = [
      SketchConstraint(ConstraintType.coincident, [pt('a', 1), pt('b', 0)]),
      SketchConstraint(ConstraintType.distance, [ln('a', 0)], value: 120),
    ];
    final s = SketchSolver(cs, byId([a, b]));
    final r = s.solve(held: {'a'});
    expect(r.ok, isTrue);
    expect(a.live!.width, closeTo(120, 1e-4));
    expect(b.live!.corners.first.dx, closeTo(a.live!.corners[1].dx, 1e-4));
    expect(b.live!.corners.first.dy, closeTo(a.live!.corners[1].dy, 1e-4));
  });

  test('parallel, perpendicular, horizontal, angle', () {
    final l1 = line('l1', const Offset(0, 0), const Offset(100, 10));
    final l2 = line('l2', const Offset(0, 50), const Offset(90, 80));
    final s = SketchSolver([
      SketchConstraint(ConstraintType.horizontal, [ln('l1', 0)]),
      SketchConstraint(ConstraintType.angle, [ln('l1', 0), ln('l2', 0)], value: 30),
    ], byId([l1, l2]));
    expect(s.solve().ok, isTrue);
    final d1 = l1.nodes.last.anchorPoint - l1.nodes.first.anchorPoint;
    final d2 = l2.nodes.last.anchorPoint - l2.nodes.first.anchorPoint;
    expect(d1.dy, closeTo(0, 1e-4));
    expect(math.atan2(d2.dy, d2.dx) * 180 / math.pi, closeTo(30, 1e-3));

    final s2 = SketchSolver([SketchConstraint(ConstraintType.perpendicular, [ln('l1', 0), ln('l2', 0)])], byId([l1, l2]));
    expect(s2.solve(held: {'l1'}).ok, isTrue);
    final e2 = l2.nodes.last.anchorPoint - l2.nodes.first.anchorPoint;
    expect(e2.dx, closeTo(0, 1e-3));
  });

  test('tangent circles and lines, radius, concentric, equal', () {
    final c1 = circle('c1', const Offset(0, 0), 20), c2 = circle('c2', const Offset(70, 5), 10);
    final l = line('l', const Offset(-50, 30), const Offset(100, 40));
    final s = SketchSolver([
      SketchConstraint(ConstraintType.radius, [ci('c1')], value: 25),
      SketchConstraint(ConstraintType.tangent, [ci('c1'), ci('c2')]),
      SketchConstraint(ConstraintType.tangent, [ln('l', 0), ci('c1')]),
      SketchConstraint(ConstraintType.equal, [ci('c2'), ci('c1')]),
    ], byId([c1, c2, l]));
    expect(s.solve().ok, isTrue);
    expect(c1.live!.width, closeTo(50, 1e-3));
    expect(c2.live!.width, closeTo(50, 1e-3));
    expect((c1.live!.center - c2.live!.center).distance, closeTo(50, 1e-3));
  });

  test('plain paths: points on lines, midpoint, symmetric, fix', () {
    final p = InkPath(nodes: [
      const BezierNode.anchor(Offset(0, 0)),
      const BezierNode.anchor(Offset(100, 3)),
      const BezierNode.anchor(Offset(60, 80)),
    ], closed: true)
      ..id = 'p';
    final m = line('m', const Offset(-10, -40), const Offset(-10, 140));
    final s = SketchSolver([
      SketchConstraint(ConstraintType.fix, [pt('p', 0)], fixed: [0, 0]),
      SketchConstraint(ConstraintType.horizontal, [ln('p', 0)]),
      SketchConstraint(ConstraintType.symmetric, [pt('p', 0), pt('p', 1), ln('m', 0)]),
      SketchConstraint(ConstraintType.pointOnLine, [pt('p', 2), ln('m', 0)]),
    ], byId([p, m]));
    expect(s.solve().ok, isTrue);
    final n = [for (final x in p.nodes) x.anchorPoint];
    expect(n[0].dx, closeTo(0, 1e-4));
    expect(n[1].dy, closeTo(0, 1e-4));
    final (a, b) = (m.nodes.first.anchorPoint, m.nodes.last.anchorPoint);
    expect(a.dx, closeTo(b.dx, 1e-4)); // the mirror line stays upright
    expect(a.dx, closeTo(n[1].dx / 2, 1e-4));
    expect(n[2].dx, closeTo(a.dx, 1e-4));
  });

  test('degrees of freedom and redundancy', () {
    final a = rect('a', const Rect.fromLTWH(0, 0, 100, 50));
    final fix = SketchConstraint(ConstraintType.fix, [pt('a', 0)], fixed: [0, 0]);
    final h = SketchConstraint(ConstraintType.horizontal, [ln('a', 0)]);
    final w = SketchConstraint(ConstraintType.distance, [ln('a', 0)], value: 100);
    final ht = SketchConstraint(ConstraintType.distance, [ln('a', 1)], value: 50);
    var s = SketchSolver([fix, h, w], byId([a]));
    var dof = s.analyse();
    expect(dof.free, 1);
    expect(dof.fixed, isEmpty);
    s = SketchSolver([fix, h, w, ht], byId([a]));
    dof = s.analyse();
    expect(dof.free, 0);
    expect(dof.fixed, {'a'});
    // The bottom being horizontal adds nothing.
    final h2 = SketchConstraint(ConstraintType.horizontal, [ln('a', 2)]);
    s = SketchSolver([fix, h, w, ht, h2], byId([a]));
    expect(s.isRedundant(h2), isTrue);
    expect(s.isRedundant(ht), isFalse);
  });

  test('conflicts are reported and change nothing', () {
    final a = rect('a', const Rect.fromLTWH(0, 0, 100, 50));
    final s = SketchSolver([
      SketchConstraint(ConstraintType.distance, [ln('a', 0)], value: 100),
      SketchConstraint(ConstraintType.distance, [ln('a', 2)], value: 80),
    ], byId([a]));
    expect(s.solve().ok, isFalse);
    expect(a.live!.width, 100);
  });

  test('constraints on missing parts are dropped', () {
    final a = rect('a', const Rect.fromLTWH(0, 0, 100, 50));
    final s = SketchSolver([
      SketchConstraint(ConstraintType.horizontal, [ln('a', 7)]),
      SketchConstraint(ConstraintType.horizontal, [ln('gone', 0)]),
    ], byId([a]));
    expect(s.constraints, isEmpty);
    expect(s.invalid.length, 2);
  });
}
