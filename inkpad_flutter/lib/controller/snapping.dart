import 'dart:ui';

import '../model/bezier_node.dart';
import '../model/element.dart';
import 'drawing_controller.dart';

/// What a point snapped to. Ported from WDPickResult's snap types.
enum SnapKind { point, edge, grid }

class SnapResult {
  final Offset point;

  /// Null when nothing was in reach (then [point] is the original point).
  final SnapKind? kind;

  const SnapResult(this.point, [this.kind]);

  bool get snapped => kind != null;
}

/// Screen pixels within which points and edges attract: Inkpad used 25 for
/// fingers (kNodeSelectionTolerance); a mouse pointer needs less.
const snapPixelsTouch = 25.0, snapPixelsMouse = 10.0;

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
      var pointDist = tolerance, edgeDist = tolerance;

      void consider(Offset candidate, bool isPoint) {
        final dist = (candidate - p).distance;
        if (isPoint && dist < pointDist) {
          pointDist = dist;
          bestPoint = candidate;
        } else if (!isPoint && dist < edgeDist) {
          edgeDist = dist;
          bestEdge = candidate;
        }
      }

      void path(InkPath path) {
        if (path.nodes.isEmpty) return;
        if (!path.controlBounds.inflate(tolerance).contains(p)) return;
        if (usePoints) {
          for (var i = 0; i < path.nodes.length; i++) {
            if (skipped(path, i)) continue;
            consider(path.nodes[i].anchorPoint, true);
          }
        }
        if (useEdges) {
          final segs = path.segments.toList();
          for (var i = 0; i < segs.length; i++) {
            // Not along the edges next to the point being dragged.
            if (skipped(path, i) || skipped(path, (i + 1) % path.nodes.length)) continue;
            consider(_nearestOn(segs[i], p), false);
          }
        }
      }

      void polygon(List<Offset> corners) {
        if (usePoints) {
          for (final c in corners) {
            consider(c, true);
          }
        }
        if (useEdges) {
          for (var i = 0; i < corners.length; i++) {
            final next = corners[(i + 1) % corners.length];
            consider(_nearestOn(BezierSegment(corners[i], corners[i], next, next), p), false);
          }
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

      // Points take priority over edges, as in Inkpad.
      if (bestPoint != null) return SnapResult(bestPoint!, SnapKind.point);
      if (bestEdge != null) return SnapResult(bestEdge!, SnapKind.edge);
    }
    if (grid && d.snapToGrid) return SnapResult(gridPoint(p), SnapKind.grid);
    return SnapResult(p);
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
