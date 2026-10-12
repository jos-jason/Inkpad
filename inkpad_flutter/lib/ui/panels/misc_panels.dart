import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/drawing.dart';
import '../chrome/chrome.dart';

/// Drawing settings. Ported in spirit from Inkpad's WDSettingsController.
class SettingsPanel extends StatelessWidget {
  final DrawingController controller;

  const SettingsPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final d = controller.drawing;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Settings'),
            SwitchListTile(
              title: const Text('Show rulers'),
              value: d.showRulers,
              onChanged: (v) {
                d.showRulers = v;
                controller.changed();
              },
            ),
            // Ported from WDSettingsController's snapping and grid rows.
            const Divider(indent: 16, endIndent: 16),
            SwitchListTile(
              title: const Text('Snap to Points'),
              value: d.snapToPoints,
              onChanged: (v) {
                d.snapToPoints = v;
                controller.changed();
              },
            ),
            SwitchListTile(
              title: const Text('Snap to Edges'),
              value: d.snapToEdges,
              onChanged: (v) {
                d.snapToEdges = v;
                controller.changed();
              },
            ),
            SwitchListTile(
              title: const Text('Snap to Grid'),
              value: d.snapToGrid,
              onChanged: (v) {
                d.snapToGrid = v;
                controller.changed();
              },
            ),
            SwitchListTile(
              title: const Text('Show Grid'),
              value: d.showGrid,
              onChanged: (v) {
                d.showGrid = v;
                controller.changed();
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: SteppedSlider(
                label: 'Grid Spacing',
                value: d.gridSpacing.clamp(1, 288),
                min: 1,
                max: 288,
                step: 1,
                format: (v) {
                  final u = InkDrawing.unitSizes[d.units] ?? 1;
                  final inUnits = v / u;
                  return '${inUnits == inUnits.roundToDouble() ? inUnits.round() : inUnits.toStringAsFixed(2)} ${d.units}';
                },
                onChanged: (v) {
                  d.gridSpacing = v.roundToDouble();
                  controller.changed();
                },
              ),
            ),
            const Divider(indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(children: [
                const Expanded(child: Text('Units', style: TextStyle(fontSize: 16))),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [for (final u in InkDrawing.unitSizes.keys) ButtonSegment(value: u, label: Text(u))],
                  selected: {d.units},
                  onSelectionChanged: (s) {
                    d.units = s.single;
                    controller.changed();
                  },
                ),
              ]),
            ),
          ],
        );
      },
    );
  }
}
