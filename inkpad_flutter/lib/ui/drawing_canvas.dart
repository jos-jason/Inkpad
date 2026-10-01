import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/drawing_controller.dart';
import '../model/element.dart';
import '../tools/tool.dart';

/// Screen-space view of the drawing: screen = doc * scale + offset.
/// Plays the role of Inkpad's WDCanvas.
class DrawingCanvas extends StatefulWidget {
  final DrawingController controller;

  const DrawingCanvas({super.key, required this.controller});

  @override
  State<DrawingCanvas> createState() => DrawingCanvasState();
}

class DrawingCanvasState extends State<DrawingCanvas> {
  static const minScale = 0.05, maxScale = 64.0;

  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _size = Size.zero;
  bool _needsFit = true;

  final Map<int, Offset> _pointers = {};
  int? _toolPointer;
  bool _panning = false;

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
    const margin = 32.0;
    final s = math.min(
      (_size.width - margin * 2) / d.width,
      (_size.height - margin * 2) / d.height,
    ).clamp(minScale, maxScale);
    setState(() {
      _scale = s;
      _offset = Offset(
        (_size.width - d.width * s) / 2,
        (_size.height - d.height * s) / 2,
      );
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

  ToolEvent _event(Offset screen) {
    final keys = HardwareKeyboard.instance;
    return ToolEvent(toDoc(screen), _scale, shift: keys.isShiftPressed, alt: keys.isAltPressed);
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;

    if (_pointers.length == 2) {
      // Second finger: abandon any tool gesture and start pinch/pan.
      if (_toolPointer != null) {
        c.tool.cancel(c);
        _toolPointer = null;
      }
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
    } else {
      _toolPointer = e.pointer;
      c.tool.begin(c, _event(e.localPosition));
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    if (_pointers.length == 2) {
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
    } else if (e.pointer == _toolPointer) {
      c.tool.move(c, _event(e.localPosition));
    }
  }

  void _onUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (e.pointer == _toolPointer) {
      if (e is PointerCancelEvent) {
        c.tool.cancel(c);
      } else {
        c.tool.end(c, _event(e.localPosition));
      }
      _toolPointer = null;
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
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

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

  static const selectionColor = Color(0xFF0A84FF);

  @override
  void paint(Canvas canvas, Size size) {
    final drawing = controller.drawing;

    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surfaceContainerHighest);

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
    drawing.render(canvas, visible);

    _paintSelection(canvas);
    controller.tool.paintOverlay(canvas, controller, scale);

    canvas.restore();
  }

  void _paintSelection(Canvas canvas) {
    final px = 1 / scale;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px
      ..color = selectionColor;

    void outlineElement(InkElement e) {
      if (e is InkStylable) {
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

    final path = controller.activePath ?? controller.singleSelectedPath;
    if (path != null) _paintNodes(canvas, path, px);
  }

  void _paintNodes(Canvas canvas, InkPath path, double px) {
    final line = Paint()
      ..strokeWidth = px
      ..color = selectionColor;
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px
      ..color = selectionColor;
    final r = 3.5 * px;

    for (final n in path.nodes) {
      for (final h in [if (n.hasInPoint) n.inPoint, if (n.hasOutPoint) n.outPoint]) {
        canvas.drawLine(n.anchorPoint, h, line);
        canvas.drawCircle(h, r * 0.8, fill);
        canvas.drawCircle(h, r * 0.8, stroke);
      }
    }
    for (final (i, n) in path.nodes.indexed) {
      final rect = Rect.fromCenter(center: n.anchorPoint, width: r * 2, height: r * 2);
      final isEnd = !path.closed && i == path.nodes.length - 1 && identical(path, controller.activePath);
      canvas.drawRect(rect, isEnd ? (Paint()..color = selectionColor) : fill);
      canvas.drawRect(rect, stroke);
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter old) => true;
}
