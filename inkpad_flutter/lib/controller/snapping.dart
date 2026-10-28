import 'dart:ui';

import '../model/bezier_node.dart';
import '../model/element.dart';
import 'drawing_controller.dart';

/// What a point snapped to. Ported from WDPickResult's snap types.
enum SnapKind { point, midpoint, center, intersection, edge, grid }

class SnapResult {
  final Offset point;

  /// Null when nothing was in reach (then [point] is the original point).
  final SnapKind? kind;

  const SnapResult(this.point, [this.kind]);

  bool get snapped => kind != null;
}

/// Screen pixels within which points and edges attract: Inkpad used 25 for
/// fingers (kNodeSelectionTolerance); a mouse pointer needs less.
const snapPixelsTouch = 25.0, snapPixelsPencil = 12.0, snapPixelsMouse = 10.0;

/// Snapping, ported from -[WDDrawingController snappedPoint:viewScale:snapFlags:]:
/// to anchor points, then path edges (including the page edges), then the
/// grid, as turned on in the drawing's settings.
extension Snapping on DrawingController {
  /// Snaps [p] (document space) using the drawing's snap settings.
  /// [tolerance] is in document units. Elements for which [skip] returns
  /// true are ignored, as are the points [skipNode] picks (the ones being
  /// dragged) and the edges next to them. [grid] false leaves out the grid.
  SnapResult snap(
    Offset p,
    double tolerance, {
    bool Function(InkElement e)? skip,
    bool Function(InkPath path, int index)? skipNode,
    bool grid = true,
  }) {
    final d = drawing;
    final usePoints = d.snapToPoints, useEdges = d.snapToEdges;
    bool skipped(InkPath path, int i) => skipNode != null && skipNode(path, i);
    if (usePoints || useEdges) {
      Offset? bestPoint, bestEdge;
      var pointKind = SnapKind.point;
      var pointDist = tolerance, edgeDist = tolerance;
      // Edges near the pointer, for finding where they cross.
      final nearby = <BezierSegment>[];

      void consider(Offset candidate, bool isPoint, [SnapKind kind = SnapKind.point]) {
        final dist = (candidate - p).distance;
        if (isPoint && dist < pointDist) {
          pointDist = dist;
          bestPoint = candidate;
          pointKind = kind;
        } else if (!isPoint && dist < edgeDist) {
          edgeDist = dist;
          bestEdge = candidate;
        }
      }

      /// Midpoints of edges (CAD snapping).
      void midpointOf(BezierSegment s) => consider(s.pointAt(0.5), true, SnapKind.midpoint);

      void path(InkPath path) {
        if (path.nodes.isEmpty) return;
        if (!path.controlBounds.inflate(tolerance).contains(p)) return;
        final segs = path.segments.toList();
        if (usePoints) {
          for (var i = 0; i < path.nodes.length; i++) {
            if (skipped(path, i)) continue;
            consider(path.nodes[i].anchorPoint, true);
          }
          // Centers of live shapes (circles, rectangles, …).
          final live = path.live;
          if (live != null && live.kind != LiveKind.line) consider(live.center, true, SnapKind.center);
        }
        for (var i = 0; i < segs.length; i++) {
          // Not along the edges next to the point being dragged.
          if (skipped(path, i) || skipped(path, (i + 1) % path.nodes.length)) continue;
          if (usePoints) midpointOf(segs[i]);
          if (useEdges) consider(_nearestOn(segs[i], p), false);
          if (usePoints && useEdges && segs[i].bounds.inflate(tolerance).contains(p)) nearby.add(segs[i]);
        }
      }

      void polygon(List<Offset> corners) {
        if (usePoints) {
          for (final c in corners) {
            consider(c, true);
          }
        }
        for (var i = 0; i < corners.length; i++) {
          final next = corners[(i + 1) % corners.length];
          final s = BezierSegment(corners[i], corners[i], next, next);
          if (usePoints) midpointOf(s);
          if (useEdges) consider(_nearestOn(s, p), false);
          if (usePoints && useEdges && s.bounds.inflate(tolerance).contains(p)) nearby.add(s);
        }
      }

      void element(InkElement e) {
        if (skip != null && skip(e)) return;
        switch (e) {
          case InkGroup g:
            g.elements.forEach(element);
            return;
          case InkPath ip:
            path(ip);
          case InkCompoundPath cp:
            cp.subpaths.forEach(path);
          case InkTextPath t:
            path(t.guide);
          case InkText t:
            polygon(t.corners);
          case InkImage i:
            polygon(i.corners);
          default:
            break;
        }
        if (e is InkStylable) e.maskedElements.forEach(element);
      }

      final active = activePath;
      if (active != null) element(active);
      for (final layer in d.layers.reversed) {
        if (!layer.visible) continue;
        for (final e in layer.elements.reversed) {
          if (!identical(e, active)) element(e);
        }
      }
      // The page's corners and edges (as Inkpad did).
      final b = d.bounds;
      polygon([b.topLeft, b.topRight, b.bottomRight, b.bottomLeft]);

      // Where nearby edges cross.
      for (var i = 0; i < nearby.length; i++) {
        for (var j = i + 1; j < nearby.length; j++) {
          for (final x in _crossings(nearby[i], nearby[j])) {
            consider(x, true, SnapKind.intersection);
          }
        }
      }

      // Points take priority over edges, as in Inkpad.
      if (bestPoint != null) return SnapResult(bestPoint!, pointKind);
      if (bestEdge != null) return SnapResult(bestEdge!, SnapKind.edge);
    }
    if (grid && d.snapToGrid) return SnapResult(gridPoint(p), SnapKind.grid);
    return SnapResult(p);
  }

  /// Where two edges cross (curves are followed as fine polylines; straight
  /// edges exactly).
  static List<Offset> _crossings(BezierSegment a, BezierSegment b) {
    if (!a.bounds.inflate(0.001).overlaps(b.bounds.inflate(0.001))) return const [];
    List<Offset> poly(BezierSegment s) => s.isStraight ? [s.a, s.b] : [for (var i = 0; i <= 32; i++) s.pointAt(i / 32)];
    final pa = poly(a), pb = poly(b);
    final out = <Offset>[];
    for (var i = 0; i + 1 < pa.length; i++) {
      for (var j = 0; j + 1 < pb.length; j++) {
        final x = _lineCrossing(pa[i], pa[i + 1], pb[j], pb[j + 1]);
        if (x != null) out.add(x);
      }
    }
    return out;
  }

  static Offset? _lineCrossing(Offset p1, Offset p2, Offset p3, Offset p4) {
    final d1 = p2 - p1, d2 = p4 - p3;
    final den = d1.dx * d2.dy - d1.dy * d2.dx;
    if (den.abs() < 1e-12) return null;
    final t = ((p3.dx - p1.dx) * d2.dy - (p3.dy - p1.dy) * d2.dx) / den;
    final u = ((p3.dx - p1.dx) * d1.dy - (p3.dy - p1.dy) * d1.dx) / den;
    // Shared end points (corners) are snapped to anyway.
    if (t <= 1e-9 || t >= 1 - 1e-9 || u <= 1e-9 || u >= 1 - 1e-9) return null;
    return p1 + d1 * t;
  }

  /// The nearest point to [p] on [s]: exact on straight edges.
  static Offset _nearestOn(BezierSegment s, Offset p) {
    if (s.isStraight) {
      final d = s.b - s.a;
      final len2 = d.dx * d.dx + d.dy * d.dy;
      if (len2 == 0) return s.a;
      final t = (((p - s.a).dx * d.dx + (p - s.a).dy * d.dy) / len2).clamp(0.0, 1.0);
      return s.a + d * t;
    }
    final (_, t) = s.closestPoint(p, samples: 16);
    return s.pointAt(t);
  }

  /// The nearest grid intersection to [p].
  Offset gridPoint(Offset p) {
    final g = drawing.gridSpacing;
    return Offset((p.dx / g).roundToDouble() * g, (p.dy / g).roundToDouble() * g);
  }

  /// How far to move a selection with [bounds], already offset by [delta],
  /// so its nearest corner lands on the grid. Ported from
  /// -[WDSelectionTool offsetSelection:inCanvas:].
  Offset gridOffset(Rect bounds, Offset delta) {
    final moved = bounds.shift(delta);
    Offset? best;
    for (final c in [moved.topLeft, moved.topRight, moved.bottomRight, moved.bottomLeft]) {
      final d = gridPoint(c) - c;
      if (best == null || d.distance < best.distance) best = d;
    }
    return delta + best!;
  }

  /// Snaps and shows where (for the canvas's snap marker).
  SnapResult snapWithFeedback(
    Offset p,
    double tolerance, {
    bool Function(InkElement e)? skip,
    bool Function(InkPath path, int index)? skipNode,
    bool grid = true,
  }) {
    final r = snap(p, tolerance, skip: skip, skipNode: skipNode, grid: grid);
    snapFeedback = r.snapped ? r : null;
    return r;
  }
}
