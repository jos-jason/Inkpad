import 'dart:math' as math;
import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../model/bezier_node.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';

/// What came out of a DXF file, with notes about anything left out.
typedef DxfImportResult = ({InkDrawing drawing, List<String> warnings});

class DxfImportException implements Exception {
  final String message;

  const DxfImportException(this.message);

  @override
  String toString() => message;
}

/// Reads a DXF file (ASCII, any version) into a Make-mode drawing at true
/// size: lines, polylines (with arcs), circles, arcs, ellipses, splines and
/// blocks. Loose lines and arcs that meet are joined into outlines, and
/// circles stay true circles. The page fits the drawing with a margin.
/// Layers keep their names; layers named like Inkpad's DXF export
/// (EXTERIOR, POCKET_D6MM, …) bring their cut types back.
DxfImportResult importDxf(String text) => _DxfReader(text).read();

/// A piece of geometry in DXF units, y up.
class _Piece {
  final List<BezierNode> nodes;
  bool closed;
  final String layer;

  /// A full circle (center, radius), kept exact.
  final (Offset, double)? circle;

  _Piece(this.nodes, this.layer, {this.closed = false, this.circle});

  Offset get start => nodes.first.anchorPoint;
  Offset get end => nodes.last.anchorPoint;
}

class _DxfReader {
  final List<(int, String)> _pairs = [];
  final _warnings = <String, int>{};
  final Map<String, List<_Piece>> _blocks = {};

  _DxfReader(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    for (var i = 0; i + 1 < lines.length; i += 2) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) throw const DxfImportException('This isn\'t a text DXF file (binary DXF isn\'t supported).');
      _pairs.add((code, lines[i + 1].trim()));
    }
  }

  void _skip(String what) => _warnings[what] = (_warnings[what] ?? 0) + 1;

  DxfImportResult read() {
    var insUnits = 0;
    final pieces = <_Piece>[];
    var i = 0;
    while (i < _pairs.length) {
      final (code, value) = _pairs[i];
      if (code == 0 && value == 'SECTION' && i + 1 < _pairs.length) {
        final name = _pairs[i + 1].$2;
        i += 2;
        if (name == 'HEADER') {
          while (i < _pairs.length && !(_pairs[i].$1 == 0 && _pairs[i].$2 == 'ENDSEC')) {
            if (_pairs[i].$1 == 9 && _pairs[i].$2 == r'$INSUNITS' && i + 1 < _pairs.length) insUnits = int.tryParse(_pairs[i + 1].$2) ?? 0;
            i++;
          }
        } else if (name == 'BLOCKS') {
          i = _readBlocks(i);
        } else if (name == 'ENTITIES') {
          i = _readEntities(i, pieces);
        } else {
          while (i < _pairs.length && !(_pairs[i].$1 == 0 && _pairs[i].$2 == 'ENDSEC')) {
            i++;
          }
        }
      }
      i++;
    }
    if (pieces.isEmpty) throw const DxfImportException('No drawing was found in this DXF file.');
    return _build(_join(pieces), insUnits);
  }

  int _readBlocks(int i) {
    while (i < _pairs.length && !(_pairs[i].$1 == 0 && _pairs[i].$2 == 'ENDSEC')) {
      if (_pairs[i].$1 == 0 && _pairs[i].$2 == 'BLOCK') {
        var name = '';
        var j = i + 1;
        while (j < _pairs.length && _pairs[j].$1 != 0) {
          if (_pairs[j].$1 == 2) name = _pairs[j].$2;
          j++;
        }
        final pieces = <_Piece>[];
        j = _readEntities(j, pieces, until: 'ENDBLK');
        _blocks[name] = pieces;
        i = j;
      }
      i++;
    }
    return i;
  }

  /// Reads entities from [i] to ENDSEC (or [until]); returns the index there.
  int _readEntities(int i, List<_Piece> out, {String until = 'ENDSEC'}) {
    while (i < _pairs.length) {
      final (code, value) = _pairs[i];
      if (code != 0) {
        i++;
        continue;
      }
      if (value == until || value == 'ENDSEC') return i;
      // This entity's group codes.
      var j = i + 1;
      final data = <(int, String)>[];
      while (j < _pairs.length && _pairs[j].$1 != 0) {
        data.add(_pairs[j]);
        j++;
      }
      if (value == 'POLYLINE') {
        // Vertices follow as separate entities until SEQEND.
        final verts = <List<(int, String)>>[];
        while (j < _pairs.length && _pairs[j].$2 == 'VERTEX' && _pairs[j].$1 == 0) {
          var k = j + 1;
          final v = <(int, String)>[];
          while (k < _pairs.length && _pairs[k].$1 != 0) {
            v.add(_pairs[k]);
            k++;
          }
          verts.add(v);
          j = k;
        }
        if (j < _pairs.length && _pairs[j].$2 == 'SEQEND') {
          j++;
          while (j < _pairs.length && _pairs[j].$1 != 0) {
            j++;
          }
        }
        _polyline(data, verts, out);
      } else {
        _entity(value, data, out);
      }
      i = j;
    }
    return i;
  }

  static double _num(List<(int, String)> d, int code, [double fallback = 0]) {
    for (final (c, v) in d) {
      if (c == code) return double.tryParse(v) ?? fallback;
    }
    return fallback;
  }

  static String _str(List<(int, String)> d, int code, [String fallback = '']) {
    for (final (c, v) in d) {
      if (c == code) return v;
    }
    return fallback;
  }

  static List<double> _all(List<(int, String)> d, int code) => [for (final (c, v) in d) if (c == code) double.tryParse(v) ?? 0];

  void _entity(String type, List<(int, String)> d, List<_Piece> out) {
    final layer = _str(d, 8, '0');
    switch (type) {
      case 'LINE':
        out.add(_Piece([BezierNode.anchor(Offset(_num(d, 10), _num(d, 20))), BezierNode.anchor(Offset(_num(d, 11), _num(d, 21)))], layer));
      case 'LWPOLYLINE':
        final xs = _all(d, 10), ys = _all(d, 20);
        // Bulges follow their vertex; collect them in order.
        final bulges = List<double>.filled(xs.length, 0);
        var v = -1;
        for (final (c, s) in d) {
          if (c == 10) v++;
          if (c == 42 && v >= 0 && v < bulges.length) bulges[v] = double.tryParse(s) ?? 0;
        }
        final closed = (_num(d, 70).toInt() & 1) == 1;
        _addBulged([for (var k = 0; k < math.min(xs.length, ys.length); k++) Offset(xs[k], ys[k])], bulges, closed, layer, out);
      case 'CIRCLE':
        final c = Offset(_num(d, 10), _num(d, 20)), r = _num(d, 40);
        if (r > 0) out.add(_Piece(const [], layer, closed: true, circle: (c, r)));
      case 'ARC':
        final c = Offset(_num(d, 10), _num(d, 20)), r = _num(d, 40);
        var a0 = _num(d, 50) * math.pi / 180, a1 = _num(d, 51) * math.pi / 180;
        while (a1 <= a0) {
          a1 += 2 * math.pi;
        }
        if (r > 0) out.add(_Piece(_arc(c, r, r, 0, a0, a1), layer));
      case 'ELLIPSE':
        final c = Offset(_num(d, 10), _num(d, 20));
        final major = Offset(_num(d, 11), _num(d, 21));
        final ratio = _num(d, 40, 1);
        var t0 = _num(d, 41), t1 = _num(d, 42, 2 * math.pi);
        while (t1 <= t0) {
          t1 += 2 * math.pi;
        }
        final full = (t1 - t0 - 2 * math.pi).abs() < 1e-6;
        final nodes = _arc(c, major.distance, major.distance * ratio, math.atan2(major.dy, major.dx), t0, t1);
        if (full && nodes.length > 1) nodes.removeLast();
        out.add(_Piece(nodes, layer, closed: full));
      case 'SPLINE':
        _spline(d, layer, out);
      case 'INSERT':
        _insert(d, out);
      case 'POINT' || 'ATTRIB' || 'ATTDEF' || 'VIEWPORT' || 'SEQEND':
        break;
      case 'TEXT' || 'MTEXT':
        _skip('text item');
      case 'DIMENSION' || 'LEADER' || 'MLEADER':
        _skip('dimension');
      case 'HATCH' || 'SOLID':
        _skip('fill (hatch)');
      default:
        _skip('${type.toLowerCase()} item');
    }
  }

  void _polyline(List<(int, String)> head, List<List<(int, String)>> verts, List<_Piece> out) {
    final flags = _num(head, 70).toInt();
    if (flags & (16 | 64) != 0) {
      _skip('3D mesh');
      return;
    }
    _addBulged(
      [for (final v in verts) Offset(_num(v, 10), _num(v, 20))],
      [for (final v in verts) _num(v, 42)],
      flags & 1 == 1,
      _str(head, 8, '0'),
      out,
    );
  }

  /// A polyline whose segments may be arcs (bulge = tan(sweep / 4)).
  void _addBulged(List<Offset> pts, List<double> bulges, bool closed, String layer, List<_Piece> out) {
    if (pts.length < 2) return;
    final nodes = <BezierNode>[BezierNode.anchor(pts.first)];
    final count = closed ? pts.length : pts.length - 1;
    for (var k = 0; k < count; k++) {
      final a = pts[k], b = pts[(k + 1) % pts.length];
      final bulge = bulges[k];
      if (bulge.abs() < 1e-9) {
        nodes.add(BezierNode.anchor(b));
        continue;
      }
      // The arc through a and b with this bulge.
      final sweep = 4 * math.atan(bulge);
      final chord = (b - a).distance;
      final r = chord / (2 * math.sin(sweep.abs() / 2));
      final mid = (a + b) / 2;
      final n = Offset(-(b - a).dy, (b - a).dx) / chord; // left of a→b
      // From the chord's middle to the center; negative for arcs over 180°.
      final h = r * math.cos(sweep.abs() / 2);
      // Counterclockwise arcs (positive bulge) have their center to the left.
      final center = mid + n * (bulge > 0 ? h : -h);
      final a0 = math.atan2(a.dy - center.dy, a.dx - center.dx);
      final arc = _arc(center, r, r, 0, a0, a0 + sweep);
      // Join: the arc's first node takes over the current end.
      final last = nodes.removeLast();
      nodes.add(BezierNode(last.inPoint, last.anchorPoint, arc.first.outPoint));
      nodes.addAll(arc.skip(1));
    }
    if (closed && nodes.length > 1 && (nodes.first.anchorPoint - nodes.last.anchorPoint).distance < 1e-9) {
      final last = nodes.removeLast();
      nodes[0] = BezierNode(last.inPoint, nodes[0].anchorPoint, nodes[0].outPoint);
    }
    out.add(_Piece(nodes, layer, closed: closed));
  }

  /// An elliptical arc (radii [rx], [ry], turned [rotation]) from angle [t0]
  /// to [t1], as Bézier curves of at most 90° each.
  static List<BezierNode> _arc(Offset c, double rx, double ry, double rotation, double t0, double t1) {
    final steps = math.max(1, ((t1 - t0).abs() / (math.pi / 2)).ceil());
    final dt = (t1 - t0) / steps;
    final k = 4 / 3 * math.tan(dt / 4);
    final cr = math.cos(rotation), sr = math.sin(rotation);
    Offset at(double t) {
      final x = rx * math.cos(t), y = ry * math.sin(t);
      return c + Offset(x * cr - y * sr, x * sr + y * cr);
    }

    Offset tangent(double t) {
      final x = -rx * math.sin(t), y = ry * math.cos(t);
      return Offset(x * cr - y * sr, x * sr + y * cr);
    }

    final nodes = <BezierNode>[];
    for (var s = 0; s <= steps; s++) {
      final t = t0 + s * dt;
      final p = at(t), d = tangent(t) * k;
      nodes.add(BezierNode(s == 0 ? p : p - d, p, s == steps ? p : p + d));
    }
    return nodes;
  }

  /// A B-spline (NURBS) followed by short curves through points on it.
  void _spline(List<(int, String)> d, String layer, List<_Piece> out) {
    final degree = _num(d, 71, 3).toInt();
    final knots = _all(d, 40);
    final weights = _all(d, 41);
    final xs = _all(d, 10), ys = _all(d, 20);
    final ctrl = [for (var k = 0; k < math.min(xs.length, ys.length); k++) Offset(xs[k], ys[k])];
    final closed = (_num(d, 70).toInt() & 1) == 1;
    List<Offset> pts;
    if (ctrl.length > degree && knots.length == ctrl.length + degree + 1) {
      final w = weights.length == ctrl.length ? weights : List.filled(ctrl.length, 1.0);
      final lo = knots[degree], hi = knots[knots.length - degree - 1];
      final n = math.max(16, ctrl.length * 8);
      pts = [for (var s = 0; s <= n; s++) _deBoor(lo + (hi - lo) * s / n, degree, knots, ctrl, w)];
    } else {
      // Only fit points: go through them.
      final fx = _all(d, 11), fy = _all(d, 21);
      pts = [for (var k = 0; k < math.min(fx.length, fy.length); k++) Offset(fx[k], fy[k])];
    }
    if (pts.length < 2) return;
    out.add(_Piece([for (final p in pts) BezierNode.anchor(p)], layer, closed: closed));
    _skip('spline (followed with short straight lines)');
  }

  static Offset _deBoor(double t, int p, List<double> knots, List<Offset> ctrl, List<double> w) {
    var k = p;
    while (k < ctrl.length - 1 && t >= knots[k + 1]) {
      k++;
    }
    final d = [for (var j = 0; j <= p; j++) (ctrl[j + k - p] * w[j + k - p], w[j + k - p])];
    for (var r = 1; r <= p; r++) {
      for (var j = p; j >= r; j--) {
        final i = j + k - p;
        final den = knots[i + p - r + 1] - knots[i];
        final a = den == 0 ? 0.0 : (t - knots[i]) / den;
        d[j] = (d[j - 1].$1 * (1 - a) + d[j].$1 * a, d[j - 1].$2 * (1 - a) + d[j].$2 * a);
      }
    }
    final (pw, ww) = d[p];
    return ww == 0 ? pw : pw / ww;
  }

  /// A placed block: its pieces moved, scaled and turned into place.
  void _insert(List<(int, String)> d, List<_Piece> out) {
    final block = _blocks[_str(d, 2)];
    if (block == null) {
      _skip('missing block');
      return;
    }
    final t = Affine.scale(_num(d, 41, 1), _num(d, 42, 1))
        .then(Affine.rotation(_num(d, 50) * math.pi / 180))
        .then(Affine.translation(_num(d, 10), _num(d, 20)));
    final layer = _str(d, 8, '0');
    for (final p in block) {
      if (p.circle case (final c, final r)) {
        final sx = Offset(t.a, t.b).distance;
        out.add(_Piece(const [], p.layer == '0' ? layer : p.layer, closed: true, circle: (t.apply(c), r * sx)));
      } else {
        out.add(_Piece([for (final n in p.nodes) n.transform(t)], p.layer == '0' ? layer : p.layer, closed: p.closed));
      }
    }
  }

  /// Joins open pieces on the same layer whose ends meet into longer
  /// outlines (closed when they come back to the start).
  List<_Piece> _join(List<_Piece> pieces) {
    final out = <_Piece>[];
    final open = <String, List<_Piece>>{};
    for (final p in pieces) {
      if (p.closed || p.circle != null) {
        out.add(p);
      } else if (p.nodes.length > 1) {
        (open[p.layer] ??= []).add(p);
      }
    }
    // Ends closer than this (in DXF units) count as meeting.
    var size = 0.0;
    for (final p in pieces) {
      for (final n in p.nodes) {
        size = math.max(size, n.anchorPoint.distance);
      }
    }
    final tol = math.max(1e-6, size * 1e-7);
    bool meet(Offset a, Offset b) => (a - b).distance <= tol;
    List<BezierNode> reversed(List<BezierNode> n) => [for (final x in n.reversed) x.flipped()];

    for (final MapEntry(key: layer, value: list) in open.entries) {
      final remaining = List.of(list);
      while (remaining.isNotEmpty) {
        var chain = List.of(remaining.removeAt(0).nodes);
        var grew = true;
        while (grew) {
          grew = false;
          for (var k = 0; k < remaining.length; k++) {
            final p = remaining[k];
            List<BezierNode>? add;
            var atEnd = true;
            if (meet(chain.last.anchorPoint, p.start)) {
              add = p.nodes;
            } else if (meet(chain.last.anchorPoint, p.end)) {
              add = reversed(p.nodes);
            } else if (meet(chain.first.anchorPoint, p.end)) {
              add = p.nodes;
              atEnd = false;
            } else if (meet(chain.first.anchorPoint, p.start)) {
              add = reversed(p.nodes);
              atEnd = false;
            }
            if (add == null) continue;
            if (atEnd) {
              final last = chain.removeLast();
              chain = [...chain, BezierNode(last.inPoint, last.anchorPoint, add.first.outPoint), ...add.skip(1)];
            } else {
              final first = chain.removeAt(0);
              chain = [...add.take(add.length - 1), BezierNode(add.last.inPoint, first.anchorPoint, first.outPoint), ...chain];
            }
            remaining.removeAt(k);
            grew = true;
            break;
          }
        }
        var closed = false;
        if (chain.length > 2 && meet(chain.first.anchorPoint, chain.last.anchorPoint)) {
          final last = chain.removeLast();
          chain[0] = BezierNode(last.inPoint, chain[0].anchorPoint, chain[0].outPoint);
          closed = true;
        }
        out.add(_Piece(chain, layer, closed: closed));
      }
    }
    return out;
  }

  DxfImportResult _build(List<_Piece> pieces, int insUnits) {
    // DXF units to points.
    final unit = switch (insUnits) {
      1 => 72.0, // inches
      2 => 864.0, // feet
      5 => 72 / 2.54, // cm
      6 => 72 / 0.0254, // m
      _ => 72 / 25.4, // mm (and unitless, the usual case)
    };
    Rect? box;
    for (final p in pieces) {
      final r = p.circle != null
          ? Rect.fromCircle(center: p.circle!.$1, radius: p.circle!.$2)
          : p.nodes.map((n) => Rect.fromPoints(n.anchorPoint, n.anchorPoint)).reduce((a, b) => a.expandToInclude(b));
      box = box == null ? r : box.expandToInclude(r);
    }
    final margin = 10 * 72 / 25.4;
    // y up to y down; the drawing's top-left at the margin.
    final t = Affine.translation(-box!.left, -box.bottom)
        .then(Affine.scale(unit, -unit))
        .then(Affine.translation(margin, margin));
    final layers = <String, InkLayer>{};
    for (final p in pieces) {
      final layer = layers.putIfAbsent(p.layer, () => InkLayer(name: p.layer == '0' ? 'Layer 1' : p.layer));
      final InkPath path;
      if (p.circle case (final c, final r)) {
        final center = t.apply(c);
        path = InkPath.live(LiveShape.inRect(LiveKind.ellipse, Rect.fromCircle(center: center, radius: r * unit)));
      } else {
        path = InkPath(nodes: [for (final n in p.nodes) n.transform(t)], closed: p.closed);
      }
      DrawingController.applyCut(path, _cutFor(p.layer, path.closed, unit));
      layer.elements.add(path);
    }
    final drawing = InkDrawing(
      width: box.width * unit + 2 * margin,
      height: box.height * unit + 2 * margin,
      layers: layers.values.toList(),
      units: insUnits == 1 || insUnits == 2 ? 'in' : 'mm',
    )..makeMode = true;
    drawing.activeLayerIndex = drawing.layers.length - 1;
    return (
      drawing: drawing,
      warnings: [for (final MapEntry(key: what, value: n) in _warnings.entries) 'Skipped $n $what${n == 1 || what.endsWith(')') ? '' : 's'}'],
    );
  }

  /// A cut from a layer name like Inkpad's export ("POCKET_D6MM"), else
  /// exterior for closed shapes and on-line for open ones.
  static CutSpec _cutFor(String layer, bool closed, double unit) {
    final name = layer.toUpperCase();
    final type = [
      for (final t in CutType.values)
        if (name.startsWith(switch (t) {
          CutType.exterior => 'EXTERIOR',
          CutType.interior => 'INTERIOR',
          CutType.online => 'ONLINE',
          CutType.pocket => 'POCKET',
          CutType.guide => 'GUIDE',
        }))
          t,
    ].firstOrNull;
    double? depth;
    final m = RegExp(r'_D(\d+(?:_\d+)?)(MM|IN)').firstMatch(name);
    if (m != null) {
      final v = double.tryParse(m.group(1)!.replaceAll('_', '.'));
      if (v != null) depth = m.group(2) == 'IN' ? v * 72 : v * 72 / 25.4;
    }
    final chosen = type ?? (closed ? CutType.exterior : CutType.online);
    return CutSpec(!closed && chosen.needsClosedShape ? CutType.online : chosen, depth: depth);
  }
}
