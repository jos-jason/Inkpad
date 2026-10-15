import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../geometry/arrowheads.dart';
import '../../model/style.dart';
import '../chrome/chrome.dart';
import '../chrome/color_editor.dart';
import '../chrome/tool_icons.dart';
import 'fill_panel.dart' show GradientControls;

enum _Kind { none, color, gradient }

/// Stroke color, caps, joins, width and dashes. Ported in spirit from
/// Inkpad's WDStrokeController.
class StrokePanel extends StatefulWidget {
  final DrawingController controller;

  const StrokePanel({super.key, required this.controller});

  @override
  State<StrokePanel> createState() => _StrokePanelState();
}

class _StrokePanelState extends State<StrokePanel> {
  static StrokeStyle _lastStroke = const StrokeStyle(width: 2);

  bool _choosingArrows = false;

  /// The selected gradient stop, while the outline is a gradient.
  int _stop = 0;

  DrawingController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final stroke = c.strokeStyle;
        if (stroke != null) _lastStroke = stroke;
        final scheme = Theme.of(context).colorScheme;

        void set(StrokeStyle? s, {bool record = true}) {
          c.strokeStyle = s;
          c.applyStyleToSelection(stroke: true, record: record);
          c.changed();
        }

        if (_choosingArrows && stroke != null) {
          return _ArrowPicker(
            stroke: stroke,
            onBack: () => setState(() => _choosingArrows = false),
            onChanged: (s) => set(s),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverHeader(
              'Stroke',
              trailing: SegmentedButton<_Kind>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Kind.none, label: Text('None')),
                  ButtonSegment(value: _Kind.color, label: Text('Color')),
                  ButtonSegment(value: _Kind.gradient, label: Text('Gradient')),
                ],
                selected: {stroke == null ? _Kind.none : (stroke.gradient == null ? _Kind.color : _Kind.gradient)},
                onSelectionChanged: (v) {
                  final base = stroke ?? _lastStroke;
                  switch (v.single) {
                    case _Kind.none:
                      set(null);
                    case _Kind.color:
                      set(base.withPaint(base.gradient?.stops[_stop.clamp(0, base.gradient!.stops.length - 1)].color ?? base.color));
                    case _Kind.gradient:
                      // From the current color to a neighbouring hue, along the shape.
                      final from = base.color.withAlpha(1);
                      _stop = 0;
                      set(base.withPaint(InkGradient.between(from, from.adjustHsb(60, 0, 0))));
                  }
                },
              ),
            ),
            if (stroke != null) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(border: Border.all(color: _editing(stroke).toColor(), width: 7)),
                  ),
                ),
                Expanded(
                  child: ColorEditor(
                    color: _editing(stroke),
                    onChangeStart: c.checkpoint,
                    onChanged: (color) {
                      final g = stroke.gradient;
                      set(g == null ? stroke.copyWith(color: color) : stroke.withPaint(g.withStopColor(_stop, color)), record: false);
                    },
                  ),
                ),
              ]),
              if (stroke.gradient case final g?)
                GradientControls(
                  gradient: g,
                  selected: _stop.clamp(0, g.stops.length - 1),
                  onSelect: (i) => setState(() => _stop = i),
                  onChangeStart: c.checkpoint,
                  onChanged: (next, selected, {record = true}) {
                    setState(() => _stop = selected);
                    set(stroke.withPaint(next), record: record);
                  },
                ),
              const Divider(indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  for (final cap in LineCap.values)
                    _GlyphToggle(
                      tooltip: '${cap.name[0].toUpperCase()}${cap.name.substring(1)} cap',
                      selected: stroke.cap == cap,
                      onTap: () => set(stroke.copyWith(cap: cap)),
                      child: StrokeGlyph(cap: StrokeStyle(cap: cap).flutterCap, color: _glyphColor(stroke.cap == cap, scheme)),
                    ),
                  const Spacer(),
                  for (final join in LineJoin.values)
                    _GlyphToggle(
                      tooltip: '${join.name[0].toUpperCase()}${join.name.substring(1)} join',
                      selected: stroke.join == join,
                      onTap: () => set(stroke.copyWith(join: join)),
                      child: StrokeGlyph(join: StrokeStyle(join: join).flutterJoin, color: _glyphColor(stroke.join == join, scheme)),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SteppedSlider(
                  value: stroke.width,
                  min: 0.1,
                  max: 50,
                  step: 0.1,
                  format: (v) => '${v.toStringAsFixed(1)} pt',
                  onChangeStart: c.checkpoint,
                  onChanged: (w) => set(stroke.copyWith(width: double.parse(w.toStringAsFixed(1))), record: false),
                ),
              ),
              const Divider(indent: 16, endIndent: 16),
              _DashEditor(
                pattern: stroke.dashPattern,
                onChangeStart: c.checkpoint,
                onChanged: (p) => set(stroke.copyWith(dashPattern: p), record: false),
                onToggle: (on) => set(stroke.copyWith(dashPattern: on ? const [10, 6] : const [])),
              ),
              const Divider(indent: 16, endIndent: 16),
              // Inkpad's arrowhead button: a preview of the current arrows.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Tooltip(
                  message: 'Arrowheads',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _choosingArrows = true),
                    child: SizedBox(
                      height: 48,
                      child: Row(children: [
                        Expanded(
                          child: stroke.hasArrows
                              ? CustomPaint(
                                  painter: ArrowPreviewPainter(
                                    start: stroke.startArrow,
                                    end: stroke.endArrow,
                                    color: scheme.onSurface,
                                  ),
                                )
                              : Row(children: [
                                  const SizedBox(width: 8),
                                  Expanded(child: Divider(thickness: 3, color: scheme.outlineVariant)),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                    child: Text('arrowheads', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 16)),
                                  ),
                                  Expanded(child: Divider(thickness: 3, color: scheme.outlineVariant)),
                                ]),
                        ),
                        const Icon(Icons.chevron_right),
                      ]),
                    ),
                  ),
                ),
              ),
            ] else
              const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  /// The color being edited: the stroke's, or the selected gradient stop's.
  InkColor _editing(StrokeStyle s) {
    final g = s.gradient;
    return g == null ? s.color : g.stops[_stop.clamp(0, g.stops.length - 1)].color;
  }

  static Color _glyphColor(bool selected, ColorScheme s) => selected ? s.primary : s.onSurface.withValues(alpha: 0.45);
}

class _GlyphToggle extends StatelessWidget {
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  const _GlyphToggle({required this.tooltip, required this.selected, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          label: tooltip,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(4), child: ClipRRect(borderRadius: BorderRadius.circular(6), child: child)),
          ),
        ),
      );
}

/// "Dashed Stroke" switch with dash / gap / dash / gap sliders, as in
/// Inkpad's stroke panel.
class _DashEditor extends StatelessWidget {
  final List<double> pattern;
  final VoidCallback onChangeStart;
  final ValueChanged<List<double>> onChanged;
  final ValueChanged<bool> onToggle;

  const _DashEditor({required this.pattern, required this.onChangeStart, required this.onChanged, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final on = pattern.isNotEmpty;
    final values = [for (var i = 0; i < 4; i++) i < pattern.length ? pattern[i] : 0.0];
    List<double> withValue(int i, double v) {
      final next = [...values]..[i] = v.roundToDouble();
      // A trailing dash/gap pair of zeros means "no second pair".
      return next[2] == 0 && next[3] == 0 ? next.sublist(0, 2) : next;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: [
        Row(children: [
          const Expanded(child: Text('Dashed Stroke', style: TextStyle(fontSize: 16))),
          Switch(value: on, onChanged: onToggle),
        ]),
        Row(children: [
          for (var i = 0; i < 4; i++)
            Expanded(
              child: Column(children: [
                Text('${values[i].round()} pt', style: TextStyle(fontSize: 15, color: on ? null : Theme.of(context).disabledColor)),
                Slider(
                  value: values[i].clamp(0, 50),
                  max: 50,
                  onChangeStart: on ? (_) => onChangeStart() : null,
                  onChanged: on ? (v) => onChanged(withValue(i, v)) : null,
                ),
                Text(i.isEven ? 'dash' : 'gap', style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
        ]),
      ]),
    );
  }
}

/// The arrowhead list: each row sets the start (left) or end (right)
/// arrow. Ported from WDArrowController.
class _ArrowPicker extends StatelessWidget {
  final StrokeStyle stroke;
  final VoidCallback onBack;
  final ValueChanged<StrokeStyle> onChanged;

  const _ArrowPicker({required this.stroke, required this.onBack, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(String id, {required bool atStart}) {
      final selected = (atStart ? stroke.startArrow : stroke.endArrow) == id;
      final name = id.isEmpty ? 'No arrowhead' : Arrowhead.named(id)!.label;
      return Expanded(
        child: Tooltip(
          message: '$name at the ${atStart ? 'start' : 'end'}',
          child: Semantics(
            button: true,
            selected: selected,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onChanged(atStart ? stroke.copyWith(startArrow: id) : stroke.copyWith(endArrow: id)),
              child: Container(
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: selected ? scheme.primaryContainer : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: CustomPaint(
                  painter: ArrowPreviewPainter(
                    start: atStart ? id : '',
                    end: atStart ? '' : id,
                    color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                    half: atStart ? ArrowPreviewHalf.start : ArrowPreviewHalf.end,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopoverHeader(
          'Arrowheads',
          leading: IconButton(tooltip: 'Back', icon: const Icon(Icons.chevron_left), onPressed: onBack),
          trailing: TextButton(
            onPressed: stroke.startArrow == stroke.endArrow ? null : () => onChanged(stroke.swappedArrows),
            child: const Text('Swap'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: Text('Start', textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelMedium)),
            Expanded(child: Text('End', textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelMedium)),
          ]),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            children: [
              for (final id in ['', ...Arrowhead.ids])
                Row(children: [cell(id, atStart: true), cell(id, atStart: false)]),
            ],
          ),
        ),
      ],
    );
  }
}

enum ArrowPreviewHalf { whole, start, end }

/// A short stroke with arrowheads, for the stroke panel.
class ArrowPreviewPainter extends CustomPainter {
  final String start, end;
  final Color color;
  final ArrowPreviewHalf half;

  ArrowPreviewPainter({required this.start, required this.end, required this.color, this.half = ArrowPreviewHalf.whole});

  @override
  void paint(Canvas canvas, Size size) {
    const width = 3.0;
    final y = size.height / 2;
    final from = Offset(half == ArrowPreviewHalf.end ? 12 : 16, y);
    final to = Offset(half == ArrowPreviewHalf.start ? size.width - 12 : size.width - 16, y);
    final s = Arrowhead.named(start), e = Arrowhead.named(end);
    final paint = Paint()..color = color;
    // Trim the line where the arrows attach, as on the canvas.
    final a = s == null ? from : from + Offset(s.insetLength(false) * width, 0);
    final b = e == null ? to : to - Offset(e.insetLength(false) * width, 0);
    canvas.drawLine(a, b, paint..strokeWidth = width);
    if (s != null) canvas.drawPath(s.path(a, width, 3.141592653589793, false), paint);
    if (e != null) canvas.drawPath(e.path(b, width, 0, false), paint);
  }

  @override
  bool shouldRepaint(ArrowPreviewPainter old) =>
      old.start != start || old.end != end || old.color != color || old.half != half;
}
