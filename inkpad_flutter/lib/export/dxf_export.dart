import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../model/drawing.dart';
import '../model/element.dart';

/// The drawing as a DXF file (AutoCAD R12, the version every CAD/CAM
/// program and laser cutter reads), at true size in mm or inches.
///
/// Live circles are written as real circles and rounded-rectangle corners
/// as real arcs; other curves are followed closely by short straight
/// segments (well under 0.01 mm off). In Make mode each cut type goes on its
/// own layer, named with its depth (e.g. POCKET_D6.35MM), so CAM software
/// can pick toolpaths by layer; otherwise layers keep their names.
Uint8List drawingToDxf(InkDrawing d) {
  final inches = d.units == 'in';
  final unit = inches ? 72.0 : 72 / 25.4;
  final out = _Dxf(height: d.height, unit: unit);
  for (final layer in d.layers) {
    if (!layer.visible) continue;
    for (final e in layer.elements) {
      for (final x in e.selfAndDescendants) {
        if (x is InkGroup || x is! InkStylable) continue;
        final name = d.makeMode ? _cutLayer(x.cut, d, inches) : _clean(layer.name);
        out.shape(x, name, d.makeMode ? _cutColor(x.cut) : 7);
      }
    }
  }
  return Uint8List.fromList(ascii.encode(out.document(inches)));
}

String _clean(String s) {
  final c = s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_\-$]'), '_');
  return c.isEmpty ? '0' : c;
}

String _cutLayer(CutSpec? cut, InkDrawing d, bool inches) {
  if (cut == null) return 'NOT_CUT';
  final name = switch (cut.type) {
    CutType.exterior => 'EXTERIOR',
    CutType.interior => 'INTERIOR',
    CutType.online => 'ONLINE',
    CutType.pocket => 'POCKET',
    CutType.guide => 'GUIDE',
  };
  if (cut.type == CutType.guide) return name;
  final depth = cut.depth ?? d.defaultCutDepth;
  final v = inches ? depth / 72 : depth * 25.4 / 72;
  var text = v.toStringAsFixed(inches ? 4 : 2);
  text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return '${name}_D$text${inches ? 'IN' : 'MM'}'.replaceAll('.', '_');
}

/// AutoCAD color numbers for each cut type's layer.
int _cutColor(CutSpec? cut) => switch (cut?.type) {
      CutType.exterior => 7,
      CutType.interior => 1,
      CutType.online => 3,
      CutType.pocket => 5,
      CutType.guide => 4,
      null => 8,
    };

class _Dxf {
  final double height, unit;
  final _entities = StringBuffer();
  final Map<String, int> _layers = {};

  _Dxf({required this.height, required this.unit});

  /// Drawing points (y down) to DXF coordinates (y up), in mm or inches.
  Offset _p(Offset q) => Offset(q.dx / unit, (height - q.dy) / unit);

  String _n(double v) {
    var s = v.toStringAsFixed(6);
    s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s == '-0' ? '0' : s;
  }

  void _code(int code, Object value) => _entities
    ..writeln(code)
    ..writeln(value is double ? _n(value) : value);

  void shape(InkStylable s, String layer, int color) {
    _layers.putIfAbsent(layer, () => color);
    if (s is InkPath) {
      final live = s.live;
      if (live != null && live.kind == LiveKind.ellipse && (live.width - live.height).abs() < 1e-9) {
        final c = _p(live.center);
        _code(0, 'CIRCLE');
        _code(8, layer);
        _code(10, c.dx);
        _code(20, c.dy);
        _code(30, 0.0);
        _code(40, live.width / 2 / unit);
        return;
      }
      if (live != null && live.kind == LiveKind.rectangle && live.cornerRadius > 0) {
        _roundedRect(live, layer);
        return;
      }
      _path(s, layer);
    } else if (s is InkCompoundPath) {
      for (final p in s.subpaths) {
        _path(p, layer);
      }
    } else if (s is InkTypography) {
      for (final p in s.outlines) {
        _path(p, layer);
      }
    }
  }

  /// A polyline through [points] (DXF coordinates); [bulges] make arcs.
  void _polyline(List<Offset> points, String layer, {required bool closed, List<double>? bulges}) {
    if (points.length < 2) return;
    _code(0, 'POLYLINE');
    _code(8, layer);
    _code(66, 1);
    _code(10, 0.0);
    _code(20, 0.0);
    _code(30, 0.0);
    _code(70, closed ? 1 : 0);
    for (final (i, p) in points.indexed) {
      _code(0, 'VERTEX');
      _code(8, layer);
      _code(10, p.dx);
      _code(20, p.dy);
      _code(30, 0.0);
      final b = bulges?[i] ?? 0;
      if (b != 0) _code(42, b);
    }
    _code(0, 'SEQEND');
    _code(8, layer);
  }

  /// A path: straight edges exactly, curves as short segments.
  void _path(InkPath p, String layer) {
    if (p.nodes.length < 2) return;
    final pts = <Offset>[_p(p.nodes.first.anchorPoint)];
    final segs = p.segments.toList();
    for (final (i, s) in segs.indexed) {
      if (s.isStraight) {
        pts.add(_p(s.b));
      } else {
        // About one segment per 0.25 pt of control polygon: well under
        // 0.01 mm off the true curve for any practical radius.
        final len = (s.outA - s.a).distance + (s.inB - s.outA).distance + (s.b - s.inB).distance;
        final n = (len / 0.25).ceil().clamp(4, 400);
        for (var k = 1; k <= n; k++) {
          pts.add(_p(s.pointAt(k / n)));
        }
      }
      // A closed path's last point repeats the first: leave it off.
      if (p.closed && i == segs.length - 1) pts.removeLast();
    }
    _polyline(pts, layer, closed: p.closed);
  }

  /// A rounded rectangle with true arcs at its corners.
  void _roundedRect(LiveShape r, String layer) {
    final w = r.width, h = r.height;
    final rad = r.cornerRadius.clamp(0.0, math.min(w, h) / 2);
    // Corner arcs go from the end of one side to the start of the next.
    final local = [
      Offset(rad, 0), Offset(w - rad, 0), // top
      Offset(w, rad), Offset(w, h - rad), // right
      Offset(w - rad, h), Offset(rad, h), // bottom
      Offset(0, h - rad), Offset(0, rad), // left
    ];
    final pts = [for (final q in local) _p(r.frame.apply(q))];
    // Arcs are quarter circles: bulge tan(90°/4), its sign the turn direction.
    final bulges = <double>[];
    for (var i = 0; i < pts.length; i++) {
      if (i.isOdd) {
        final a = pts[i], b = pts[(i + 1) % pts.length], next = pts[(i + 2) % pts.length];
        final turn = (b - a).dx * (next - b).dy - (b - a).dy * (next - b).dx;
        bulges.add(turn >= 0 ? math.tan(math.pi / 8) : -math.tan(math.pi / 8));
      } else {
        bulges.add(0);
      }
    }
    _polyline(pts, layer, closed: true, bulges: bulges);
  }

  String document(bool inches) {
    final sb = StringBuffer();
    void code(int c, Object v) => sb
      ..writeln(c)
      ..writeln(v);
    code(0, 'SECTION');
    code(2, 'HEADER');
    code(9, r'$ACADVER');
    code(1, 'AC1009');
    code(9, r'$INSUNITS');
    code(70, inches ? 1 : 4);
    code(9, r'$MEASUREMENT');
    code(70, inches ? 0 : 1);
    code(0, 'ENDSEC');
    code(0, 'SECTION');
    code(2, 'TABLES');
    code(0, 'TABLE');
    code(2, 'LAYER');
    code(70, _layers.length);
    for (final MapEntry(key: name, value: color) in _layers.entries) {
      code(0, 'LAYER');
      code(2, name);
      code(70, 0);
      code(62, color);
      code(6, 'CONTINUOUS');
    }
    code(0, 'ENDTAB');
    code(0, 'ENDSEC');
    code(0, 'SECTION');
    code(2, 'ENTITIES');
    sb.write(_entities);
    code(0, 'ENDSEC');
    code(0, 'EOF');
    return sb.toString();
  }
}
