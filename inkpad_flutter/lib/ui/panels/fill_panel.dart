import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/style.dart';
import '../chrome/chrome.dart';
import '../chrome/color_editor.dart';

enum _Kind { none, color, gradient }

/// None / Color / Gradient fill editor. Ported in spirit from Inkpad's
/// WDFillController and WDGradientController.
class FillPanel extends StatefulWidget {
  final DrawingController controller;

  const FillPanel({super.key, required this.controller});

  @override
  State<FillPanel> createState() => _FillPanelState();
}

class _FillPanelState extends State<FillPanel> {
  int _stop = 0;
  static InkColor _lastColor = const InkColor(0.35, 0.6, 0.95);

  DrawingController get c => widget.controller;

  void _apply(InkPaint? paint, {bool record = true}) {
    c.fillPaint = paint;
    c.applyStyleToSelection(fill: true, record: record);
    c.changed();
  }

  void _setKind(_Kind kind, InkPaint? current) {
    switch (kind) {
      case _Kind.none:
        _apply(null);
      case _Kind.color:
        _apply(current is InkGradient ? current.stops[_stop.clamp(0, current.stops.length - 1)].color : _lastColor);
      case _Kind.gradient:
        // Inkpad's default: the current color fading to transparent.
        final base = current is InkColor ? current : _lastColor;
        _stop = 0;
        _apply(InkGradient.between(base.withAlpha(0), base, type: GradientType.radial));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final paint = c.fillPaint;
        if (paint is InkColor) _lastColor = paint;
        final kind = switch (paint) { null => _Kind.none, InkGradient() => _Kind.gradient, _ => _Kind.color };
        final gradient = paint is InkGradient ? paint : null;
        if (gradient != null && _stop >= gradient.stops.length) _stop = gradient.stops.length - 1;
        final editing = gradient != null ? gradient.stops[_stop].color : paint as InkColor?;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverHeader(
              'Fill',
              trailing: SegmentedButton<_Kind>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Kind.none, label: Text('None')),
                  ButtonSegment(value: _Kind.color, label: Text('Color')),
                  ButtonSegment(value: _Kind.gradient, label: Text('Gradient')),
                ],
                selected: {kind},
                onSelectionChanged: (s) => _setKind(s.single, paint),
              ),
            ),
            if (editing != null)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: SizedBox(width: 52, height: 52, child: CustomPaint(painter: _SwatchPainter(editing))),
                ),
                Expanded(
                  child: ColorEditor(
                    color: editing,
                    onChangeStart: c.checkpoint,
                    onChanged: (color) => _apply(
                      gradient != null ? gradient.withStopColor(_stop, color) : color,
                      record: false,
                    ),
                  ),
                ),
              ]),
            if (gradient != null) ...[
              const Divider(indent: 16, endIndent: 16),
              GradientControls(
                gradient: gradient,
                selected: _stop,
                onSelect: (i) => setState(() => _stop = i),
                onChangeStart: c.checkpoint,
                onChanged: (g, selected, {record = true}) {
                  setState(() => _stop = selected);
                  _apply(g, record: record);
                },
              ),
            ],
            if (editing == null) const SizedBox(height: 12),
          ],
        );
      },
    );
  }
}

/// A gradient's preview, linear/radial choice and stops bar, shared by the
/// fill and stroke panels.
class GradientControls extends StatelessWidget {
  final InkGradient gradient;
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onChangeStart;

  /// A new gradient (with the stop now selected); [record] is false while
  /// a stop is being dragged.
  final void Function(InkGradient gradient, int selected, {bool record}) onChanged;

  const GradientControls({
    super.key,
    required this.gradient,
    required this.selected,
    required this.onSelect,
    required this.onChangeStart,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(children: [
            SizedBox(width: 56, height: 56, child: CustomPaint(painter: _GradientPreview(gradient))),
            const SizedBox(height: 6),
            Row(children: [
              for (final type in GradientType.values)
                Tooltip(
                  message: type == GradientType.linear ? 'Linear' : 'Radial',
                  child: InkWell(
                    onTap: () => onChanged(gradient.copyWith(type: type), selected),
                    child: Container(
                      width: 26,
                      height: 22,
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: gradient.type == type ? Theme.of(context).colorScheme.primary : Colors.transparent,
                          width: 2,
                        ),
                        gradient: type == GradientType.linear
                            ? const LinearGradient(colors: [Colors.black, Colors.white])
                            : const RadialGradient(colors: [Colors.white, Colors.black]),
                      ),
                    ),
                  ),
                ),
            ]),
          ]),
          const SizedBox(width: 16),
          Expanded(
            child: GradientStopsBar(
              gradient: gradient,
              selected: selected,
              onSelect: onSelect,
              onChangeStart: onChangeStart,
              onChanged: (g, i) => onChanged(g, i, record: false),
            ),
          ),
        ]),
      );
}

/// The gradient with a marker per stop. Tap a marker to select it, drag it
/// sideways to move it, drag it down off the bar to remove it (keeping at
/// least two), or tap the bar to add a stop. As in Inkpad's gradient editor.
class GradientStopsBar extends StatefulWidget {
  final InkGradient gradient;
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onChangeStart;
  final void Function(InkGradient gradient, int selected) onChanged;

  const GradientStopsBar({
    super.key,
    required this.gradient,
    required this.selected,
    required this.onSelect,
    required this.onChangeStart,
    required this.onChanged,
  });

  @override
  State<GradientStopsBar> createState() => _GradientStopsBarState();
}

class _GradientStopsBarState extends State<GradientStopsBar> {
  static const _barHeight = 56.0, _marker = 26.0, _removeDistance = 40.0;
  bool _removing = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.gradient;
    final primary = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth - _marker;
      double toOffset(double x) => ((x - _marker / 2) / w).clamp(0.0, 1.0);

      List<GradientStop> sorted(List<GradientStop> stops) => [...stops]..sort((a, b) => a.offset.compareTo(b.offset));

      return SizedBox(
        height: _barHeight + _marker + 10,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: _marker / 2,
            right: _marker / 2,
            top: 0,
            height: _barHeight,
            child: GestureDetector(
              onTapUp: (d) {
                // Add a stop where tapped, in the color already there.
                final offset = (d.localPosition.dx / w).clamp(0.0, 1.0);
                final added = sorted([...g.stops, GradientStop(offset, g.colorAt(offset))]);
                widget.onChangeStart();
                widget.onChanged(g.copyWith(stops: added), added.indexWhere((s) => s.offset == offset));
              },
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: Colors.black54)),
                child: CustomPaint(painter: _GradientBarPainter(g)),
              ),
            ),
          ),
          for (final (i, stop) in g.stops.indexed)
            Positioned(
              left: stop.offset * w,
              top: _barHeight + 4,
              child: Semantics(
                button: true,
                selected: i == widget.selected,
                label: 'Gradient stop ${i + 1}',
                child: GestureDetector(
                  onTap: () => widget.onSelect(i),
                  onPanStart: (_) {
                    widget.onSelect(i);
                    widget.onChangeStart();
                  },
                  onPanUpdate: (d) {
                    final box = context.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(d.globalPosition);
                    setState(() => _removing = g.stops.length > 2 && local.dy > _barHeight + _marker + _removeDistance);
                    if (_removing) return;
                    final moved = [...g.stops]..[i] = GradientStop(toOffset(local.dx), stop.color);
                    final s = sorted(moved);
                    widget.onChanged(g.copyWith(stops: s), s.indexOf(moved[i]));
                  },
                  onPanEnd: (_) {
                    if (_removing) {
                      final removed = [...g.stops]..removeAt(i);
                      widget.onChanged(g.copyWith(stops: removed), (i - 1).clamp(0, removed.length - 1));
                    }
                    setState(() => _removing = false);
                  },
                  child: Opacity(
                    opacity: _removing && i == widget.selected ? 0.3 : 1,
                    child: Container(
                      width: _marker,
                      height: _marker,
                      decoration: BoxDecoration(
                        border: Border.all(color: i == widget.selected ? primary : Colors.black38, width: i == widget.selected ? 3 : 1),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: CustomPaint(painter: _SwatchPainter(stop.color)),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
    });
  }
}

class _GradientBarPainter extends CustomPainter {
  final InkGradient gradient;

  _GradientBarPainter(this.gradient);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    paintChecker(canvas, r);
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          colors: [for (final s in gradient.stops) s.color.toColor()],
          stops: [for (final s in gradient.stops) s.offset],
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(_GradientBarPainter old) => old.gradient != gradient;
}

class _GradientPreview extends CustomPainter {
  final InkGradient gradient;

  _GradientPreview(this.gradient);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    paintChecker(canvas, r);
    final shader = gradient.copyWith(clearGeometry: true).shader(r, 1);
    canvas.drawRect(r, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_GradientPreview old) => old.gradient != gradient;
}

/// A color swatch over a checkerboard, split diagonally to show the opaque
/// version beside the transparent one (as in the screenshots).
class _SwatchPainter extends CustomPainter {
  final InkColor color;

  _SwatchPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    paintChecker(canvas, r);
    canvas.drawRect(r, Paint()..color = color.toColor());
    if (color.alpha < 1) {
      final opaque = Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(opaque, Paint()..color = color.withAlpha(1).toColor());
    }
    canvas.drawRect(r, Paint()..style = PaintingStyle.stroke..color = Colors.black26);
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.color != color;
}
