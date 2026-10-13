import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/drawing.dart';
import '../ai/ai_settings_page.dart';
import '../chrome/chrome.dart';
import '../make/length_field.dart';

/// Drawing settings. Ported in spirit from Inkpad's WDSettingsController.
class SettingsPanel extends StatelessWidget {
  final DrawingController controller;

  const SettingsPanel({super.key, required this.controller});

  /// Units, precision and material for Make mode.
  List<Widget> _makeSettings(BuildContext context, InkDrawing d) {
    final theme = Theme.of(context);
    void set(void Function() change) {
      change();
      controller.changed();
    }

    Widget row(String label, Widget field) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(children: [Expanded(child: Text(label)), field]),
        );

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'mm', label: Text('mm')),
            ButtonSegment(value: 'cm', label: Text('cm')),
            ButtonSegment(value: 'in', label: Text('inches')),
          ],
          selected: {d.units == 'cm' || d.units == 'in' ? d.units : 'mm'},
          onSelectionChanged: (s) => set(() => d.units = s.single),
        ),
      ),
      if (d.units == 'in') ...[
        SwitchListTile(
          dense: true,
          title: const Text('Fractions of an inch'),
          value: d.fractionalInches,
          onChanged: (v) => set(() => d.fractionalInches = v),
        ),
        if (d.fractionalInches)
          row(
            'Finest fraction',
            DropdownButton<int>(
              value: d.inchDenominator,
              items: [for (final n in const [8, 16, 32, 64]) DropdownMenuItem(value: n, child: Text('1/$n″'))],
              onChanged: (v) => set(() => d.inchDenominator = v ?? 32),
            ),
          ),
      ] else
        row(
          'Shown to',
          DropdownButton<int>(
            value: d.decimals,
            items: [
              for (final n in const [0, 1, 2, 3])
                DropdownMenuItem(value: n, child: Text(n == 0 ? '1 ${d.units}' : '0.${'0' * (n - 1)}1 ${d.units}')),
            ],
            onChanged: (v) => set(() => d.decimals = v ?? 2),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text('Material and bit', style: theme.textTheme.titleSmall),
      ),
      row('Material thickness', LengthField(value: d.materialThickness, lengths: d.lengths, onChanged: (v) => set(() => d.materialThickness = v), width: 120)),
      row('Bit diameter', LengthField(value: d.bitDiameter, lengths: d.lengths, onChanged: (v) => set(() => d.bitDiameter = v), width: 120)),
      row('Default cut depth', LengthField(value: d.defaultCutDepth, lengths: d.lengths, onChanged: (v) => set(() => d.defaultCutDepth = v), width: 120)),
      const SizedBox(height: 8),
    ];
  }

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
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('AI services…'),
              subtitle: const Text('Your own Claude, OpenAI-compatible or Ollama'),
              onTap: () => AiSettingsPage.open(context),
            ),
            SwitchListTile(
              title: const Text('Show rulers'),
              value: d.showRulers,
              onChanged: (v) {
                d.showRulers = v;
                controller.changed();
              },
            ),
            // Make mode: exact sizes and cutting.
            SwitchListTile(
              title: const Text('Make mode'),
              subtitle: const Text('Exact sizes and cuts, for CNC routers (Shaper Origin) and laser cutters'),
              value: d.makeMode,
              onChanged: controller.setMakeMode,
            ),
            if (d.makeMode) ..._makeSettings(context, d),
            const Divider(indent: 16, endIndent: 16),
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
