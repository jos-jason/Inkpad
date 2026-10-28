import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/drawing_controller.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../model/style.dart';
import '../text/font_library.dart';
import 'make/cut_preview.dart';
import 'make/constraint_painter.dart';
import '../tools/tool.dart';

/// Where the canvas is looking: screen = doc * scale + offset. Shared with
/// the rulers and the zoom readout.
class CanvasView extends ChangeNotifier {
  double _scale = 1;
  Offset _offset = Offset.zero;

  double get scale => _scale;
  Offset get offset => _offset;

  set scale(double v) {
    if (v == _scale) return;
    _scale = v;
    notifyListeners();
  }

  set offset(Offset v) {
    if (v == _offset) return;
    _offset = v;
    notifyListeners();
  }

  Offset toDoc(Offset screen) => (screen - _offset) / _scale;
  Offset toScreen(Offset doc) => doc * _scale + _offset;
}

/// Screen-space view of the drawing. Plays the role of Inkpad's WDCanvas.
class DrawingCanvas extends StatefulWidget {
  final DrawingController controller;
  final CanvasView? view;

  /// Space covered by floating panels, kept clear when fitting the page.
  final EdgeInsets fitPadding;

  const DrawingCanvas({super.key, required this.controller, this.view, this.fitPadding = EdgeInsets.zero});

  @override
  State<DrawingCanvas> createState() => DrawingCanvasState();
}

class DrawingCanvasState extends State<DrawingCanvas> {
  static const minScale = 0.05, maxScale = 64.0;

  late final CanvasView view = widget.view ?? CanvasView();
  double get _scale => view.scale;
  set _scale(double v) => view.scale = v;
  Offset get _offset => view.offset;
  set _offset(Offset v) => view.offset = v;
  Size _size = Size.zero;
  bool _needsFit = true;

  final Map<int, Offset> _pointers = {};
  int? _toolPointer;
  bool _panning = false;

  /// A finger's touch waits until it moves or lifts before reaching the
  /// tool (as Inkpad's canvas did), so two fingers landing together zoom
  /// without selecting, deselecting or nudging anything.
  PointerDownEvent? _pendingDown;
  int _pendingCount = 1;

  /// A second finger down while the first drags: a modifier, not a zoom.
  bool _secondary = false;
  PointerEvent? _lastToolEvent;

  /// How far (screen pixels) a finger moves before it counts as a drag.
  static const _touchDragStart = 3.0;

  // Pinch state.
  double _pinchStartDistance = 0;
  double _pinchStartScale = 1;
  Offset _pinchDocFocal = Offset.zero;

  double _trackpadLastScale = 1;

  DrawingController get c => widget.controller;

  double get scale => _scale;

  Offset toDoc(Offset screen) => (screen - _offset) / _scale;
  Offset toScreen(Offset doc) => doc * _scale + _offset;

  void fitToScreen() {
    if (_size.isEmpty) return;
    final d = c.drawing;
    const margin = 24.0;
    final area = widget.fitPadding.deflateRect(Offset.zero & _size).deflate(margin);
    if (area.isEmpty) return;
    final s = math.min(area.width / d.width, area.height / d.height).clamp(minScale, maxScale);
    setState(() {
      _scale = s;
      _offset = area.center - Offset(d.width * s / 2, d.height * s / 2);
    });
  }

  void zoomBy(double factor, [Offset? screenFocal]) {
    final focal = screenFocal ?? _size.center(Offset.zero);
    final docFocal = toDoc(focal);
    setState(() {
      _scale = (_scale * factor).clamp(minScale, maxScale);
      _offset = focal - docFocal * _scale;
    });
  }

  void actualSize() => zoomBy(1 / _scale);

  ToolEvent _event(PointerEvent e, {int count = 1}) {
    final keys = HardwareKeyboard.instance;
    return ToolEvent(
      toDoc(e.localPosition),
      _scale,
      shift: keys.isShiftPressed,
      alt: keys.isAltPressed,
      secondary: _secondary,
      count: count,
      touch: e.kind == PointerDeviceKind.touch,
      pencil: e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus,
    );
  }

  /// Starts the tool with the waiting finger's touch.
  void _beginPending() {
    final down = _pendingDown;
    if (down == null) return;
    _pendingDown = null;
    c.tool.begin(c, _event(down, count: _pendingCount));
  }

  // Click counting, for double clicks and double taps.
  static const _multiTapTime = Duration(milliseconds: 350);
  static const _multiTapSlop = 24.0; // screen pixels
  Duration? _lastDownTime;
  Offset _lastDownPosition = Offset.zero;
  int _tapCount = 0;

  int _countTap(PointerDownEvent e) {
    final last = _lastDownTime;
    final quick = last != null && e.timeStamp - last <= _multiTapTime;
    final close = (e.localPosition - _lastDownPosition).distance <= _multiTapSlop;
    _tapCount = quick && close ? _tapCount + 1 : 1;
    _lastDownTime = e.timeStamp;
    _lastDownPosition = e.localPosition;
    return _tapCount;
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    c.snapFeedback = null;

    if (_pointers.length == 2) {
      // A second finger while the first is dragging: a modifier (Inkpad's
      // secondary touch), applied straight away.
      if (_toolPointer != null && _pendingDown == null) {
        _secondary = true;
        final last = _lastToolEvent;
        if (last != null) c.tool.move(c, _event(last));
        return;
      }
      // Two fingers together: zoom and pan. The first finger's touch never
      // reached the tool.
      _pendingDown = null;
      _toolPointer = null;
      _panning = false;
      final pts = _pointers.values.toList();
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _pinchStartScale = _scale;
      _pinchDocFocal = toDoc((pts[0] + pts[1]) / 2);
      return;
    }
    if (_pointers.length > 2) return;

    final secondary = e.kind == PointerDeviceKind.mouse &&
        (e.buttons & (kMiddleMouseButton | kSecondaryMouseButton)) != 0;
    if (c.tool.pansView || secondary || _spaceDown) {
      _panning = true;
      return;
    }
    _toolPointer = e.pointer;
    _secondary = false;
    _lastToolEvent = e;
    final count = _countTap(e);
    if (e.kind == PointerDeviceKind.touch) {
      // Wait to see whether a second finger follows.
      _pendingDown = e;
      _pendingCount = count;
    } else {
      c.tool.begin(c, _event(e, count: count));
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    if (e.pointer == _toolPointer) {
      final down = _pendingDown;
      if (down != null) {
        if ((e.localPosition - down.localPosition).distance < _touchDragStart) return;
        _beginPending();
      }
      _lastToolEvent = e;
      c.tool.move(c, _event(e));
    } else if (_toolPointer != null) {
      // The modifier finger moving: nothing to do.
    } else if (_pointers.length == 2) {
      final pts = _pointers.values.toList();
      final focal = (pts[0] + pts[1]) / 2;
      final dist = (pts[0] - pts[1]).distance;
      setState(() {
        if (_pinchStartDistance > 0) {
          _scale = (_pinchStartScale * dist / _pinchStartDistance).clamp(minScale, maxScale);
        }
        _offset = focal - _pinchDocFocal * _scale;
      });
    } else if (_panning) {
      setState(() => _offset += e.delta);
    }
  }

  void _onUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (e.pointer == _toolPointer) {
      if (e is PointerCancelEvent) {
        _pendingDown = null;
        c.tool.cancel(c);
      } else {
        // A tap: the tool sees it begin and end.
        _beginPending();
        c.tool.end(c, _event(e));
      }
      _toolPointer = null;
      _secondary = false;
      _lastToolEvent = null;
      if (c.snapFeedback != null) {
        c.snapFeedback = null;
        c.changed();
      }
    } else if (_toolPointer != null && _secondary && _pointers.length < 2) {
      // The modifier finger lifted: back to plain dragging.
      _secondary = false;
      final last = _lastToolEvent;
      if (last != null) c.tool.move(c, _event(last));
    }
    if (_pointers.isEmpty) _panning = false;
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final keys = HardwareKeyboard.instance;
      if (keys.isControlPressed || keys.isMetaPressed) {
        zoomBy(math.exp(-e.scrollDelta.dy / 200), e.localPosition);
      } else {
        setState(() => _offset -= e.scrollDelta);
      }
    } else if (e is PointerScaleEvent) {
      zoomBy(e.scale, e.localPosition);
    }
  }

  bool get _spaceDown =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.space);

  @override
  void initState() {
    super.initState();
    c.addListener(_onControllerChanged);
    ImageData.decodes.addListener(_onControllerChanged);
    FontLibrary.instance.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(DrawingCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    ImageData.decodes.removeListener(_onControllerChanged);
    FontLibrary.instance.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// The page size last shown: when it changes (Canvas Size…), the page is
  /// fitted to the screen again.
  Size? _pageSize;

  void _onControllerChanged() {
    final page = Size(c.drawing.width, c.drawing.height);
    if (_pageSize != null && page != _pageSize) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? fitToScreen() : null);
    _pageSize = page;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _size = constraints.biggest;
      if (_needsFit && !_size.isEmpty) {
        _needsFit = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => fitToScreen());
      }
      return MouseRegion(
        cursor: c.tool.pansView ? SystemMouseCursors.grab : SystemMouseCursors.precise,
        child: Listener(
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onUp,
          onPointerSignal: _onSignal,
          onPointerPanZoomStart: (_) => _trackpadLastScale = 1,
          onPointerPanZoomUpdate: (e) {
            final factor = e.scale / _trackpadLastScale;
            _trackpadLastScale = e.scale;
            setState(() => _offset += e.panDelta);
            if (factor != 1) zoomBy(factor, e.localPosition);
          },
          child: ClipRect(
            child: CustomPaint(
              size: Size.infinite,
              painter: _CanvasPainter(
                controller: c,
                scale: _scale,
                offset: _offset,
                colors: Theme.of(context).colorScheme,
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _CanvasPainter extends CustomPainter {
  final DrawingController controller;
  final double scale;
  final Offset offset;
  final ColorScheme colors;

  _CanvasPainter({
    required this.controller,
    required this.scale,
    required this.offset,
    required this.colors,
  });

  /// The highlight color of the selection's layer (as in Inkpad).
  late final Color selectionColor = () {
    final first = controller.selection.firstOrNull;
    final layer = first == null ? null : controller.layerOf(first);
    return (layer?.highlightColor ?? InkLayer.defaultHighlight).toColor();
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final drawing = controller.drawing;

    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surfaceContainerLow);

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    // Artboard.
    final board = drawing.bounds;
    canvas.drawRect(
      board.shift(Offset(0, 2 / scale)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 / scale),
    );
    canvas.drawRect(board, Paint()..color = Colors.white);

    final visible = Rect.fromLTWH(-offset.dx / scale, -offset.dy / scale, size.width / scale, size.height / scale);
    if (drawing.showGrid) _paintGrid(canvas, visible);
    drawing.render(canvas, visible);
    if (drawing.makeMode && drawing.showCutPreview) CutPreview.paint(canvas, drawing);
    ConstraintPainter.paint(canvas, controller, scale);

    _paintSelection(canvas);
    controller.tool.paintOverlay(canvas, controller, scale);
    _paintSnap(canvas);

    canvas.restore();
  }

  /// The grid over the page, under the drawing. Ported from -[WDCanvas
  /// drawGrid:]: lines never closer than 10 screen pixels.
  void _paintGrid(Canvas canvas, Rect visible) {
    final d = controller.drawing;
    final area = visible.intersect(d.bounds);
    if (area.isEmpty || d.gridSpacing <= 0) return;
    var spacing = d.gridSpacing;
    if (spacing * scale < 10) spacing *= (10 / (spacing * scale)).ceilToDouble();
    final paint = Paint()
      ..color = const Color(0x20000000)
      ..strokeWidth = 1 / scale;
    for (var x = (area.left / spacing).ceilToDouble() * spacing; x <= area.right; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, d.height), paint);
    }
    for (var y = (area.top / spacing).ceilToDouble() * spacing; y <= area.bottom; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(d.width, y), paint);
    }
  }

  /// Where the dragged point snapped: a square on a point, a circle on an
  /// edge, a small cross on the grid.
  void _paintSnap(Canvas canvas) {
    final s = controller.snapFeedback;
    if (s == null) return;
    final px = 1 / scale;
    final p = s.point;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * px
      ..color = const Color(0xFFFF2D78);
    final halo = Paint()..color = const Color(0xCCFFFFFF);
    switch (s.kind!) {
      case SnapKind.point:
        final r = Rect.fromCenter(center: p, width: 10 * px, height: 10 * px);
        canvas.drawRect(r.inflate(px), halo);
        canvas.drawRect(r, ring);
      case SnapKind.edge:
        canvas.drawCircle(p, 6 * px, halo);
        canvas.drawCircle(p, 5 * px, ring);
      case SnapKind.grid:
        canvas.drawLine(p - Offset(5 * px, 0), p + Offset(5 * px, 0), ring);
        canvas.drawLine(p - Offset(0, 5 * px), p + Offset(0, 5 * px), ring);
      case SnapKind.midpoint:
        final tri = Path()
          ..moveTo(p.dx, p.dy - 6 * px)
          ..lineTo(p.dx + 6 * px, p.dy + 5 * px)
          ..lineTo(p.dx - 6 * px, p.dy + 5 * px)
          ..close();
        canvas.drawPath(tri, halo);
        canvas.drawPath(tri, ring);
      case SnapKind.center:
        canvas.drawCircle(p, 6 * px, halo);
        canvas.drawCircle(p, 5 * px, ring);
        canvas.drawLine(p - Offset(3 * px, 0), p + Offset(3 * px, 0), ring);
        canvas.drawLine(p - Offset(0, 3 * px), p + Offset(0, 3 * px), ring);
      case SnapKind.intersection:
        canvas.drawCircle(p, 6 * px, halo);
        canvas.drawLine(p - Offset(5 * px, 5 * px), p + Offset(5 * px, 5 * px), ring);
        canvas.drawLine(p - Offset(5 * px, -5 * px), p + Offset(5 * px, -5 * px), ring);
    }
  }

  void _paintSelection(Canvas canvas) {
    final px = 1 / scale;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px
      ..color = selectionColor;

    void outlineElement(InkElement e) {
      if (e is InkText) {
        canvas.drawPath(Path()..addPolygon(e.corners, true), outline);
      } else if (e is InkTextPath) {
        canvas.drawPath(e.guide.toFlutterPath(), outline);
        if (controller.selection.length == 1) {
          // The start knob, draggable with the select tool.
          final at = e.pointAt(e.startOffset);
          if (at != null) {
            canvas.drawCircle(at.$1, 6 * px, Paint()..color = Colors.white);
            canvas.drawCircle(at.$1, 6 * px, outline);
            canvas.drawLine(at.$1, at.$1 + Offset.fromDirection(at.$2 - math.pi / 2, e.fontSize), outline);
          }
        }
      } else if (e is InkImage) {
        canvas.drawPath(Path()..addPolygon(e.corners, true), outline);
      } else if (e is InkStylable) {
        canvas.drawPath(e.toFlutterPath(), outline);
      } else if (e is InkGroup) {
        e.elements.forEach(outlineElement);
      }
    }

    for (final e in controller.selection) {
      outlineElement(e);
    }

    final bounds = controller.selectionBounds;
    if (bounds != null &&
        (controller.selection.length > 1 || controller.selection.any((e) => e is InkGroup))) {
      canvas.drawRect(bounds, outline);
    }

    if (controller.tool is DirectSelectTool) {
      // Multi-select: the points of every selected object (and any path with
      // selected points), handles on selected points only.
      final paths = {
        for (final MapEntry(key: p, value: owner) in controller.pathOwners().entries)
          if (p.live == null && (controller.selection.contains(owner) || controller.selectedNodes.containsKey(p))) p,
      };
      for (final p in paths) {
        canvas.drawPath(p.toFlutterPath(), outline);
        _paintNodes(canvas, p, px, selected: controller.selectedNodes[p] ?? const {});
      }
    } else {
      final active = controller.activePath;
      final path = active ?? controller.singleSelectedPath;
      // A live shape's points aren't edited directly, so they aren't shown.
      // As in Inkpad, only the selected point shows its handles (the path
      // being drawn shows all of its own).
      if (path != null && path.live == null) {
        _paintNodes(canvas, path, px, selected: active != null ? null : (controller.selectedNodes[path] ?? const {}));
      }
    }

    final shape = controller.singleSelectedStylable;
    final fill = shape?.fill;
    if (shape != null && fill is InkGradient) _paintGradientHandles(canvas, fill, shape.bounds, px);
  }

  /// The gradient's start and end, draggable with the select tool.
  /// Ported in spirit from -[WDElement drawGradientControlsWithViewTransform:].
  void _paintGradientHandles(Canvas canvas, InkGradient g, Rect bounds, double px) {
    final geom = g.fitted(bounds);
    final a = geom.documentStart, b = geom.documentEnd;
    canvas.drawLine(a, b, Paint()..color = Colors.white..strokeWidth = 3 * px);
    canvas.drawLine(a, b, Paint()..color = selectionColor..strokeWidth = px);
    for (final (pt, color, radius) in [(a, g.stops.first.color, 6.0), (b, g.stops.last.color, 5.0)]) {
      canvas.drawCircle(pt, radius * px, Paint()..color = Colors.white);
      canvas.drawCircle(pt, (radius - 1.5) * px, Paint()..color = color.toColor());
      canvas.drawCircle(pt, radius * px, Paint()..style = PaintingStyle.stroke..strokeWidth = px..color = selectionColor);
    }
  }

  /// [selected]: only these points are filled and show their handles.
  void _paintNodes(Canvas canvas, InkPath path, double px, {Set<int>? selected}) {
    final line = Paint()
      ..strokeWidth = px
      ..color = selectionColor;
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px
      ..color = selectionColor;
    final r = 3.5 * px;

    for (final (i, n) in path.nodes.indexed) {
      if (selected != null && !selected.contains(i)) continue;
      for (final h in [if (n.hasInPoint) n.inPoint, if (n.hasOutPoint) n.outPoint]) {
        canvas.drawLine(n.anchorPoint, h, line);
        canvas.drawCircle(h, r * 0.8, fill);
        canvas.drawCircle(h, r * 0.8, stroke);
      }
    }
    for (final (i, n) in path.nodes.indexed) {
      final rect = Rect.fromCenter(center: n.anchorPoint, width: r * 2, height: r * 2);
      final isEnd = !path.closed && i == path.nodes.length - 1 && identical(path, controller.activePath);
      final filled = isEnd || (selected?.contains(i) ?? false);
      canvas.drawRect(rect, filled ? (Paint()..color = selectionColor) : fill);
      canvas.drawRect(rect, stroke);
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter old) => true;
}
