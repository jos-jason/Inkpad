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
