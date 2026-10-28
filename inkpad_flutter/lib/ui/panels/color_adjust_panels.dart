import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/style.dart';
import '../chrome/chrome.dart';

/// One slider of an adjustment panel: shown as -100…100 (or degrees).
class _Adjustment {
  final String label;
  final double min, max;
  final String unit;
  final Gradient? track;

  const _Adjustment(this.label, {this.min = -100, this.max = 100, this.unit = '', this.track});
}

/// A live color adjustment over the selection, previewed as the sliders
/// move. Done (or tapping outside) keeps it; Cancel puts the colors back.
/// Ported from WDColorBalanceController and WDHueSaturationController.
class _AdjustPanel extends StatefulWidget {
  final DrawingController controller;
  final String title;
  final List<_Adjustment> adjustments;

  /// The color change for the slider values (as shown).
  final InkColor Function(InkColor color, List<double> values) adjust;

  const _AdjustPanel({required this.controller, required this.title, required this.adjustments, required this.adjust});

  @override
  State<_AdjustPanel> createState() => _AdjustPanelState();
}

class _AdjustPanelState extends State<_AdjustPanel> {
  late final List<double> _values = List.filled(widget.adjustments.length, 0);
  bool _finished = false;

  DrawingController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.beginColorAdjustment();
  }

  @override
  void dispose() {
    // Closed by tapping outside: keep the adjustment.
    if (!_finished) c.endColorAdjustment();
    super.dispose();
  }

  void _set(int i, double v) {
    setState(() => _values[i] = v);
    c.previewColorAdjustment((color) => widget.adjust(color, _values));
  }

  void _close({required bool cancel}) {
    _finished = true;
    c.endColorAdjustment(cancel: cancel);
    Navigator.of(context).pop();
  }

  void _reset() {
    setState(() => _values.fillRange(0, _values.length, 0));
    c.previewColorAdjustment((color) => color);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopoverHeader(
          widget.title,
          leading: TextButton(onPressed: () => _close(cancel: true), child: const Text('Cancel')),
          trailing: TextButton(onPressed: () => _close(cancel: false), child: const Text('Done')),
        ),
        for (final (i, a) in widget.adjustments.indexed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SteppedSlider(
                label: a.label,
                value: _values[i],
                min: a.min,
                max: a.max,
                step: 1,
                format: (v) => '${v > 0 ? '+' : ''}${v.round()}${a.unit}',
                onChanged: (v) => _set(i, v.roundToDouble()),
              ),
              if (a.track != null)
                // What the slider does: the colors from one end to the other.
                Padding(
                  padding: const EdgeInsets.fromLTRB(52, 0, 56, 4),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(gradient: a.track, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
            ]),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: TextButton(onPressed: _values.every((v) => v == 0) ? null : _reset, child: const Text('Reset')),
          ),
        ),
      ],
    );
  }
}

/// Shifts the red, green and blue of every color (fills, gradients,
/// outlines, shadows) in the selection.
class ColorBalancePanel extends StatelessWidget {
  final DrawingController controller;

  const ColorBalancePanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => _AdjustPanel(
        controller: controller,
        title: 'Color Balance',
        adjustments: const [
          _Adjustment('Cyan – Red', track: LinearGradient(colors: [Color(0xFF00FFFF), Color(0xFFFF0000)])),
          _Adjustment('Magenta – Green', track: LinearGradient(colors: [Color(0xFFFF00FF), Color(0xFF00FF00)])),
          _Adjustment('Yellow – Blue', track: LinearGradient(colors: [Color(0xFFFFFF00), Color(0xFF0000FF)])),
        ],
        adjust: (color, v) => color.balance(v[0] / 100, v[1] / 100, v[2] / 100),
      );
}

/// Shifts the hue, saturation and brightness of every color in the
/// selection.
class HueSaturationPanel extends StatelessWidget {
  final DrawingController controller;

  const HueSaturationPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => _AdjustPanel(
        controller: controller,
        title: 'Hue and Saturation',
        adjustments: [
          _Adjustment(
            'Hue',
            min: -180,
            max: 180,
            unit: '°',
            track: LinearGradient(colors: [for (var h = -180; h <= 180; h += 30) InkColor.hsb(h.toDouble(), 1, 1).toColor()]),
          ),
          const _Adjustment('Saturation', track: LinearGradient(colors: [Color(0xFF808080), Color(0xFF00BFFF)])),
          const _Adjustment('Brightness', track: LinearGradient(colors: [Color(0xFF000000), Color(0xFFFFFFFF)])),
        ],
        adjust: (color, v) => color.adjustHsb(v[0], v[1] / 100, v[2] / 100),
      );
}
