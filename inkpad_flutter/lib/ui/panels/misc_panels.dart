import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/drawing.dart';
import '../chrome/chrome.dart';

/// Opacity (and, soon, shadow) for the selection or new shapes.
class OpacityPanel extends StatelessWidget {
  final DrawingController controller;

  const OpacityPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PopoverHeader('Opacity'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SteppedSlider(
              value: controller.opacity * 100,
              min: 0,
              max: 100,
              step: 1,
              format: (v) => '${v.round()}%',
              onChangeStart: controller.checkpoint,
              onChanged: (v) => controller.setOpacity(v.roundToDouble() / 100, record: false),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text('Shadows are coming soon.', style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

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
