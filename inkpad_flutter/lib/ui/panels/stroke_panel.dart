import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/style.dart';
import '../chrome/chrome.dart';
import '../chrome/color_editor.dart';
import '../chrome/tool_icons.dart';

/// Stroke color, caps, joins, width and dashes. Ported in spirit from
/// Inkpad's WDStrokeController.
class StrokePanel extends StatelessWidget {
  final DrawingController controller;

  const StrokePanel({super.key, required this.controller});

  static StrokeStyle _lastStroke = const StrokeStyle(width: 2);

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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverHeader(
              'Stroke',
              trailing: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('None')),
                  ButtonSegment(value: true, label: Text('Color')),
                ],
                selected: {stroke != null},
                onSelectionChanged: (v) => set(v.single ? _lastStroke : null),
              ),
            ),
            if (stroke != null) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(border: Border.all(color: stroke.color.toColor(), width: 7)),
                  ),
                ),
                Expanded(
                  child: ColorEditor(
                    color: stroke.color,
                    onChangeStart: c.checkpoint,
                    onChanged: (color) => set(stroke.copyWith(color: color), record: false),
                  ),
                ),
              ]),
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
              Tooltip(
                message: 'Arrowheads are coming soon',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Row(children: [
                    Expanded(child: Divider(thickness: 3, color: scheme.outlineVariant)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('arrowheads', style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.35), fontSize: 16)),
                    ),
                    Expanded(child: Divider(thickness: 3, color: scheme.outlineVariant)),
                  ]),
                ),
              ),
            ] else
              const SizedBox(height: 12),
          ],
        );
      },
    );
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
