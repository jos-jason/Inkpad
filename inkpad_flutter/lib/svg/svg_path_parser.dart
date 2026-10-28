import 'dart:math' as math;
import 'dart:ui';

import '../model/bezier_node.dart';
import '../model/element.dart';

/// Parses SVG path data (`d` attributes) into bezier subpaths.
/// Supports every SVG path command, absolute and relative:
/// M L H V C S Q T A Z. Quadratics and arcs become cubic curves.
/// Ported in spirit from WDSVGPathParser.
List<InkPath> parseSvgPathData(String d) => _PathBuilder(d).build();

class _Scanner {
  final String s;
  int i = 0;

  _Scanner(this.s);

  static final _number = RegExp(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?');

  void skipSeparators() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      // space, tab, CR, LF, comma
      if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0a || c == 0x2c) {
        i++;
      } else {
        break;
      }
    }
  }

  bool get atEnd {
    skipSeparators();
    return i >= s.length;
  }

  /// True if the next token is a number (so a command letter can repeat).
  bool get nextIsNumber {
    skipSeparators();
    return i < s.length && _number.matchAsPrefix(s, i) != null;
  }

  String? command() {
    skipSeparators();
    if (i >= s.length) return null;
    final c = s[i];
    if (RegExp(r'[MmLlHhVvCcSsQqTtAaZz]').hasMatch(c)) {
      i++;
      return c;
    }
    return null;
  }

  double number() {
    skipSeparators();
    final m = _number.matchAsPrefix(s, i);
    if (m == null) throw FormatException('Expected a number at $i in path data');
    i = m.end;
    return double.parse(m.group(0)!);
  }

  /// Arc flags may be written without separators ("a1 1 0 01 5 5").
  bool flag() {
    skipSeparators();
    if (i < s.length && (s[i] == '0' || s[i] == '1')) {
      return s[i++] == '1';
    }
    throw FormatException('Expected an arc flag at $i in path data');
  }
}

class _PathBuilder {
  final _Scanner scan;
  final List<InkPath> paths = [];
  InkPath? _current;

  Offset _point = Offset.zero;
  Offset _start = Offset.zero;
  Offset? _lastCubicControl;
  Offset? _lastQuadControl;

  _PathBuilder(String d) : scan = _Scanner(d);

  List<InkPath> build() {
    String? cmd;
    try {
      while (!scan.atEnd) {
        final next = scan.command();
        if (next != null) {
          cmd = next;
        } else if (cmd == null || !scan.nextIsNumber) {
          break; // garbage: stop, keeping what was parsed (as browsers do)
        } else if (cmd == 'M') {
          cmd = 'L'; // extra pairs after a moveto are linetos
        } else if (cmd == 'm') {
          cmd = 'l';
        }
        _run(cmd);
        if (cmd == 'Z' || cmd == 'z') cmd = null;
      }
    } on FormatException {
      // Malformed tail: keep everything parsed so far.
    }
    return paths.where((p) => p.nodes.length > 1).toList();
  }

  void _run(String cmd) {
    final rel = cmd == cmd.toLowerCase();
    Offset pt() {
      final x = scan.number(), y = scan.number();
      return rel ? _point + Offset(x, y) : Offset(x, y);
    }

    final upper = cmd.toUpperCase();
    switch (upper) {
      case 'M':
        _moveTo(pt());
        _clearControls();
      case 'L':
        _lineTo(pt());
        _clearControls();
      case 'H':
        final x = scan.number();
        _lineTo(Offset(rel ? _point.dx + x : x, _point.dy));
        _clearControls();
      case 'V':
        final y = scan.number();
        _lineTo(Offset(_point.dx, rel ? _point.dy + y : y));
        _clearControls();
      case 'C':
        final c1 = pt(), c2 = pt(), p = pt();
        _cubicTo(c1, c2, p);
        _lastCubicControl = c2;
        _lastQuadControl = null;
      case 'S':
        final c1 = _lastCubicControl == null ? _point : _point * 2 - _lastCubicControl!;
        final c2 = pt(), p = pt();
        _cubicTo(c1, c2, p);
        _lastCubicControl = c2;
        _lastQuadControl = null;
      case 'Q':
        final q = pt(), p = pt();
        _quadTo(q, p);
      case 'T':
        final q = _lastQuadControl == null ? _point : _point * 2 - _lastQuadControl!;
        final p = pt();
        _quadTo(q, p);
      case 'A':
        final rx = scan.number(), ry = scan.number(), rotation = scan.number();
        final large = scan.flag(), sweep = scan.flag();
        final p = pt();
        _arcTo(rx, ry, rotation, large, sweep, p);
        _clearControls();
      case 'Z':
        _close();
        _clearControls();
    }
  }

  void _clearControls() {
    _lastCubicControl = null;
    _lastQuadControl = null;
  }

  void _moveTo(Offset p) {
    _current = InkPath(nodes: [BezierNode.anchor(p)]);
    paths.add(_current!);
    _point = _start = p;
  }

  /// Drawing after a closepath (without a moveto) starts a new subpath
  /// at the closed subpath's start point.
  InkPath get _path {
    if (_current == null || _current!.closed) _moveTo(_point);
    return _current!;
  }

  void _lineTo(Offset p) {
    _path.nodes.add(BezierNode.anchor(p));
    _point = p;
  }

  void _cubicTo(Offset c1, Offset c2, Offset p) {
    final nodes = _path.nodes;
    final last = nodes.last;
    nodes[nodes.length - 1] = BezierNode(last.inPoint, last.anchorPoint, c1);
    nodes.add(BezierNode(c2, p, p));
    _point = p;
  }

  void _quadTo(Offset q, Offset p) {
    final p0 = _point;
    _cubicTo(p0 + (q - p0) * (2 / 3), p + (q - p) * (2 / 3), p);
    _lastQuadControl = q;
    _lastCubicControl = null;
  }

  void _close() {
    final path = _current;
    if (path == null || path.closed) return;
    final nodes = path.nodes;
    // An explicit segment back to the start duplicates the first node; merge.
    if (nodes.length > 1 && (nodes.last.anchorPoint - nodes.first.anchorPoint).distance < 1e-6) {
      final last = nodes.removeLast();
      nodes[0] = BezierNode(last.inPoint, nodes[0].anchorPoint, nodes[0].outPoint);
    }
    path.closed = true;
    _point = _start;
  }

  /// Elliptical arc to cubic beziers (SVG 1.1 implementation notes F.6.5).
  void _arcTo(double rx, double ry, double rotationDeg, bool largeArc, bool sweep, Offset end) {
    final start = _point;
    if (start == end) return;
    rx = rx.abs();
    ry = ry.abs();
    if (rx == 0 || ry == 0) {
      _lineTo(end);
      return;
    }

    final phi = rotationDeg * math.pi / 180;
    final cosPhi = math.cos(phi), sinPhi = math.sin(phi);

    // Step 1: compute (x1', y1').
    final dx = (start.dx - end.dx) / 2, dy = (start.dy - end.dy) / 2;
    final x1p = cosPhi * dx + sinPhi * dy;
    final y1p = -sinPhi * dx + cosPhi * dy;

    // Scale up radii that are too small.
    final lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
      final s = math.sqrt(lambda);
      rx *= s;
      ry *= s;
    }

    // Step 2: compute (cx', cy').
    final num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    final den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coef = den == 0 ? 0.0 : math.sqrt(math.max(0, num / den));
    if (largeArc == sweep) coef = -coef;
    final cxp = coef * (rx * y1p / ry);
    final cyp = coef * -(ry * x1p / rx);

    // Step 3: compute (cx, cy).
    final cx = cosPhi * cxp - sinPhi * cyp + (start.dx + end.dx) / 2;
    final cy = sinPhi * cxp + cosPhi * cyp + (start.dy + end.dy) / 2;

    // Step 4: angles.
    double angle(double ux, double uy, double vx, double vy) {
      final a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
      return a;
    }

    final theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep && delta > 0) delta -= 2 * math.pi;
    if (sweep && delta < 0) delta += 2 * math.pi;

    // Split into segments of at most 90 degrees.
    final count = math.max(1, (delta.abs() / (math.pi / 2)).ceil());
    final step = delta / count;
    final k = 4 / 3 * math.tan(step / 4);

    Offset onEllipse(double t) {
      final x = rx * math.cos(t), y = ry * math.sin(t);
      return Offset(cosPhi * x - sinPhi * y + cx, sinPhi * x + cosPhi * y + cy);
    }

    Offset derivative(double t) {
      final x = -rx * math.sin(t), y = ry * math.cos(t);
      return Offset(cosPhi * x - sinPhi * y, sinPhi * x + cosPhi * y);
    }

    var t = theta1;
    for (var i = 0; i < count; i++) {
      final t2 = t + step;
      final p1 = onEllipse(t), p2 = i == count - 1 ? end : onEllipse(t2);
      _cubicTo(p1 + derivative(t) * k, p2 - derivative(t2) * k, p2);
      t = t2;
    }
  }
}
