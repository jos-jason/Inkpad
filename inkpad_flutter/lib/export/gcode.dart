import 'dart:math' as math;
import 'dart:ui';

import '../geometry/pathfinder.dart';
import '../model/drawing.dart';
import '../model/element.dart';

/// One tool move in machine terms: to [x], [y] (in the drawing's points,
/// y down as on the page) and depth [z] (points; 0 is the material's top,
/// negative cuts in), cutting or a rapid move.
class ToolMove {
  final Offset at;
  final double z;
  final bool rapid;

  const ToolMove(this.at, this.z, {this.rapid = false});
}

/// A machining program: the moves, and its G-code.
class GcodeProgram {
  final List<ToolMove> moves;
  final String code;

  /// How far the tool cuts and travels, in points, and roughly how long
  /// it takes in minutes.
  final double cutLength, travel, minutes;

  /// Shapes that couldn't be machined (too small for the bit, …).
  final List<String> notes;

  const GcodeProgram(this.moves, this.code, this.cutLength, this.travel, this.minutes, this.notes);
}

/// Makes G-code (for GRBL and similar controllers) from a Make-mode
/// drawing's cuts: pockets cleared in rings, holes and on-line cuts, then
/// parts cut around (last, so they're held while the rest is cut). Each
/// cut goes down in passes of [CamSettings.stepDown] to its depth; through
/// cuts keep holding tabs. The origin is the page's bottom-left corner at
/// the material's top, X to the right and Y away from you.
GcodeProgram makeGcode(InkDrawing d, CamSettings cam, {String title = 'Inkpad'}) {
  final inches = d.units == 'in';
  final unit = inches ? 72.0 : 72 / 25.4;
  final r = d.bitDiameter / 2;
  final notes = <String>[];
  // (priority, polylines (closed?), depth, through cut?)
  final ops = <(int, List<(List<Offset>, bool)>, double, bool)>[];

  for (final layer in d.layers) {
    if (!layer.visible) continue;
    for (final e in layer.elements) {
      for (final x in e.selfAndDescendants) {
        if (x is! InkStylable || x is InkGroup) continue;
        final cut = x.cut;
        if (cut == null || cut.type == CutType.guide) continue;
        final depth = cut.depth ?? d.defaultCutDepth;
        if (depth <= 0) continue;
        final through = depth >= d.materialThickness - 1e-6;
        switch (cut.type) {
          case CutType.pocket:
            final rings = <List<(List<Offset>, bool)>>[];
            var ring = Pathfinder.offsetShape(x, -r);
            var guard = 0;
            while (ring != null && guard++ < 500) {
              rings.add(_flatten(ring));
              ring = Pathfinder.offsetShape(ring, -math.max(d.bitDiameter * cam.stepOver, 0.1));
            }
            if (rings.isEmpty) {
              notes.add('A pocket is too small for the bit');
              continue;
            }
            // Clear from the middle outwards.
            ops.add((0, [for (final rg in rings.reversed) ...rg], depth, false));
          case CutType.interior:
            final p = Pathfinder.offsetShape(x, -(r + cut.offset));
            if (p == null) {
              notes.add('A hole is too small for the bit');
              continue;
            }
            ops.add((2, _flatten(p), depth, through));
          case CutType.online:
            ops.add((1, _flatten(x), depth, false));
          case CutType.exterior:
            final p = Pathfinder.offsetShape(x, r + cut.offset);
            if (p != null) ops.add((3, _flatten(p), depth, through));
          case CutType.guide:
            break;
        }
      }
    }
  }
  ops.sort((a, b) => a.$1.compareTo(b.$1));

  final moves = <ToolMove>[];
  final safe = cam.safeHeight;
  var pos = Offset.zero;
  void rapidTo(Offset p) {
    moves.add(ToolMove(pos, safe, rapid: true));
    moves.add(ToolMove(p, safe, rapid: true));
    pos = p;
  }

  // Polylines in machine order (nearest next), each cut in depth passes.
  for (final (priority, polys, depth, through) in ops) {
    final remaining = List.of(polys.where((p) => p.$1.length >= 2));
    while (remaining.isNotEmpty) {
      // The nearest start next (for closed paths, rotate to the nearest point).
      var bestI = 0, bestJ = 0;
      var bestD = double.infinity;
      for (final (i, (pts, closed)) in remaining.indexed) {
        for (var j = 0; j < (closed ? pts.length : 1); j++) {
          final dist = (pts[j] - pos).distance;
          if (dist < bestD) {
            bestD = dist;
            bestI = i;
            bestJ = j;
          }
        }
      }
      var (pts, closed) = remaining.removeAt(bestI);
      if (closed) {
        pts = [...pts.sublist(bestJ), ...pts.sublist(0, bestJ)];
        pts = _direction(pts, climb: cam.climb, outside: priority == 3);
        pts = [...pts, pts.first];
      }
      final passes = math.max(1, (depth / math.max(cam.stepDown, 0.01)).ceil());
      final tabTop = -(depth - cam.tabHeight);
      final useTabs = through && closed && cam.tabs && cam.tabCount > 0 && cam.tabHeight < depth;
      final tabZones = useTabs ? _tabZones(pts, cam.tabCount, cam.tabWidth + d.bitDiameter) : const <(double, double)>[];
      rapidTo(pts.first);
      for (var k = 1; k <= passes; k++) {
        final z = -depth * k / passes;
        final raised = useTabs && z < tabTop;
        moves.add(ToolMove(pts.first, raised && _inZone(0, tabZones) ? tabTop : z));
        var along = 0.0;
        for (var i = 1; i < pts.length; i++) {
          final a = pts[i - 1], b = pts[i];
          final len = (b - a).distance;
          if (!raised) {
            moves.add(ToolMove(b, z));
          } else {
            // Over tabs, stay at the tab's top.
            final cuts = <double>{0, len};
            for (final (s0, s1) in tabZones) {
              if (s0 > along && s0 < along + len) cuts.add(s0 - along);
              if (s1 > along && s1 < along + len) cuts.add(s1 - along);
            }
            final sorted = cuts.toList()..sort();
            for (var q = 1; q < sorted.length; q++) {
              final t0 = sorted[q - 1], t1 = sorted[q];
              final mid = along + (t0 + t1) / 2;
              final zz = _inZone(mid, tabZones) ? tabTop : z;
              final p0 = a + (b - a) * (t0 / len), p1 = a + (b - a) * (t1 / len);
              if (moves.last.z != zz) moves.add(ToolMove(p0, zz));
              moves.add(ToolMove(p1, zz));
            }
          }
          along += len;
        }
        // Open paths go back to their start between passes.
        if (!closed && k < passes) {
          moves.add(ToolMove(pts.last, safe, rapid: true));
          moves.add(ToolMove(pts.first, safe, rapid: true));
        }
      }
      pos = pts.last;
      moves.add(ToolMove(pos, safe, rapid: true));
    }
  }
  moves.add(ToolMove(pos, safe, rapid: true));
  moves.add(ToolMove(Offset(0, d.height), safe, rapid: true));

  // G-code text, and totals.
  final sb = StringBuffer();
  String n(double v) {
    var s = v.toStringAsFixed(inches ? 4 : 3);
    s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s == '-0' ? '0' : s;
  }

  String xy(Offset p) => 'X${n(p.dx / unit)} Y${n((d.height - p.dy) / unit)}';
  final speed = inches ? 1 / 25.4 : 1.0;
  sb.writeln('(${title.replaceAll(RegExp(r'[()]'), '')} — made with Inkpad)');
  sb.writeln('(Bit ${d.lengths.format(d.bitDiameter)}; origin: bottom-left of the page, Z0 on top of the material)');
  sb.writeln(inches ? 'G20' : 'G21');
  sb.writeln('G90 G17 G94');
  sb.writeln('G0 Z${n(safe / unit)}');
  sb.writeln('M3 S${cam.spindle}');
  sb.writeln('G4 P2');
  var cut = 0.0, travel = 0.0, minutes = 0.0;
  var last = const ToolMove(Offset.zero, 0, rapid: true);
  var z = safe;
  for (final m in moves) {
    final dxy = (m.at - last.at).distance;
    final dz = (m.z - z).abs();
    if (m.rapid) {
      if (m.z != z) sb.writeln('G0 Z${n(m.z / unit)}');
      if (dxy > 1e-9) sb.writeln('G0 ${xy(m.at)}');
      travel += dxy + dz;
      minutes += (dxy + dz) / unit * (inches ? 25.4 : 1) / 5000; // rapids, roughly
    } else if (dxy < 1e-9 && m.z != z) {
      sb.writeln('G1 Z${n(m.z / unit)} F${n(cam.plunge * speed)}');
      cut += dz;
      minutes += dz / (72 / 25.4) / cam.plunge;
    } else {
      sb.writeln('G1 ${xy(m.at)}${m.z != z ? ' Z${n(m.z / unit)}' : ''} F${n(cam.feed * speed)}');
      final len = math.sqrt(dxy * dxy + dz * dz);
      cut += len;
      minutes += len / (72 / 25.4) / cam.feed;
    }
    z = m.z;
    last = m;
  }
  sb.writeln('M5');
  sb.writeln('M2');
  return GcodeProgram(moves, sb.toString(), cut, travel, minutes, notes);
}

/// Polylines following [s] closely (curves as short segments).
List<(List<Offset>, bool)> _flatten(InkStylable s) {
  final paths = switch (s) {
    InkPath p => [p],
    InkCompoundPath c => c.subpaths,
    _ => <InkPath>[],
  };
  final out = <(List<Offset>, bool)>[];
  for (final p in paths) {
    if (p.nodes.length < 2) continue;
    final pts = <Offset>[p.nodes.first.anchorPoint];
    for (final seg in p.segments) {
      if (seg.isStraight) {
        pts.add(seg.b);
      } else {
        final len = (seg.outA - seg.a).distance + (seg.inB - seg.outA).distance + (seg.b - seg.inB).distance;
        final k = (len / 0.5).ceil().clamp(4, 400);
        for (var i = 1; i <= k; i++) {
          pts.add(seg.pointAt(i / k));
        }
      }
    }
    if (p.closed && (pts.first - pts.last).distance < 1e-9) pts.removeLast();
    out.add((pts, p.closed));
  }
  return out;
}

/// [pts] (a closed loop) in the cutting direction: with the spindle turning
/// clockwise, conventional milling goes clockwise on the page (y down)
/// around outsides and counterclockwise around holes; climb is the reverse.
List<Offset> _direction(List<Offset> pts, {required bool climb, required bool outside}) {
  var area = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    area += a.dx * b.dy - b.dx * a.dy;
  }
  final clockwiseOnPage = area > 0; // y down
  final wantClockwise = outside != climb;
  if (clockwiseOnPage == wantClockwise) return pts;
  return [pts.first, ...pts.skip(1).toList().reversed];
}

/// Evenly spaced tab zones along a closed loop, as (start, end) distances.
List<(double, double)> _tabZones(List<Offset> pts, int count, double width) {
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += (pts[i] - pts[i - 1]).distance;
  }
  if (total <= width * count) return const [];
  return [
    for (var k = 0; k < count; k++) (total * (k + 0.5) / count - width / 2, total * (k + 0.5) / count + width / 2),
  ];
}

bool _inZone(double s, List<(double, double)> zones) => zones.any((z) => s >= z.$1 && s <= z.$2);
