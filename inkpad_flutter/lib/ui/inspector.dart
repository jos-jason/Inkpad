import 'package:flutter/material.dart';

import '../controller/drawing_controller.dart';
import '../model/style.dart';

/// Swatches modelled on Inkpad's default swatch library.
const _swatches = <InkColor>[
  InkColor(0, 0, 0),
  InkColor(0.25, 0.25, 0.25),
  InkColor(0.5, 0.5, 0.5),
  InkColor(0.75, 0.75, 0.75),
  InkColor(1, 1, 1),
  InkColor(0.93, 0.26, 0.21),
  InkColor(1, 0.58, 0),
  InkColor(1, 0.8, 0),
  InkColor(0.3, 0.75, 0.3),
  InkColor(0, 0.6, 0.55),
  InkColor(0.35, 0.6, 0.95),
  InkColor(0.2, 0.3, 0.8),
  InkColor(0.55, 0.3, 0.8),
  InkColor(0.9, 0.35, 0.6),
  InkColor(0.55, 0.35, 0.2),
];

/// Fill / stroke / layers panel. A simplified take on Inkpad's
/// WDFillController, WDStrokeController and WDLayerController.
class Inspector extends StatelessWidget {
  final DrawingController controller;

  const Inspector({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final stroke = c.strokeStyle;
        final text = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Fill', style: text.titleSmall),
            const SizedBox(height: 8),
            _SwatchGrid(
              selected: c.fillColor,
              onPick: (color) {
                c.fillColor = color;
                c.applyStyleToSelection(fill: true);
                c.changed();
              },
            ),
            const SizedBox(height: 20),
            Text('Stroke', style: text.titleSmall),
            const SizedBox(height: 8),
            _SwatchGrid(
              selected: stroke?.color,
              onPick: (color) {
                c.strokeStyle = color == null
                    ? null
                    : (stroke ?? const StrokeStyle()).copyWith(color: color);
                c.applyStyleToSelection(stroke: true);
                c.changed();
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Width'),
                Expanded(
                  child: Slider(
                    value: (stroke?.width ?? 1).clamp(0.5, 40),
                    min: 0.5,
                    max: 40,
                    onChanged: stroke == null
                        ? null
                        : (w) {
                            c.strokeStyle = stroke.copyWith(width: w);
                            c.changed();
                          },
                    onChangeEnd: stroke == null ? null : (_) => c.applyStyleToSelection(stroke: true),
                  ),
                ),
                SizedBox(width: 36, child: Text(stroke == null ? '–' : stroke.width.toStringAsFixed(1))),
              ],
            ),
            const Divider(height: 32),
            Row(
              children: [
                Expanded(child: Text('Layers', style: text.titleSmall)),
                IconButton(
                  tooltip: 'Add layer',
                  icon: const Icon(Icons.add),
                  onPressed: c.addLayer,
                ),
                IconButton(
                  tooltip: 'Delete layer',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: c.drawing.layers.length > 1 ? c.deleteActiveLayer : null,
                ),
              ],
            ),
            // Top layer first, as in Inkpad.
            for (var i = c.drawing.layers.length - 1; i >= 0; i--)
              _LayerTile(controller: c, index: i),
          ],
        );
      },
    );
  }
}

class _SwatchGrid extends StatelessWidget {
  final InkColor? selected;
  final ValueChanged<InkColor?> onPick;

  const _SwatchGrid({required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    final accent = Theme.of(context).colorScheme.primary;
    Widget swatch(InkColor? color) {
      final isSelected = color == selected;
      return Tooltip(
        message: color?.hexValue ?? 'None',
        child: InkWell(
          onTap: () => onPick(color),
          customBorder: const CircleBorder(),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color?.toColor() ?? Colors.white,
              border: Border.all(
                color: isSelected ? accent : outline,
                width: isSelected ? 3 : 1,
              ),
            ),
            child: color == null
                ? const Icon(Icons.block, size: 18, color: Colors.red)
                : null,
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [swatch(null), ..._swatches.map(swatch)],
    );
  }
}

class _LayerTile extends StatelessWidget {
  final DrawingController controller;
  final int index;

  const _LayerTile({required this.controller, required this.index});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final layer = c.drawing.layers[index];
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      selected: c.drawing.activeLayerIndex == index,
      title: Text(layer.name),
      subtitle: Text('${layer.elements.length} objects'),
      onTap: () => c.activateLayer(index),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: layer.visible ? 'Hide' : 'Show',
            icon: Icon(layer.visible ? Icons.visibility : Icons.visibility_off),
            onPressed: () {
              layer.visible = !layer.visible;
              c.selectNone();
              c.changed();
            },
          ),
          IconButton(
            tooltip: layer.locked ? 'Unlock' : 'Lock',
            icon: Icon(layer.locked ? Icons.lock : Icons.lock_open),
            onPressed: () {
              layer.locked = !layer.locked;
              c.selectNone();
              c.changed();
            },
          ),
        ],
      ),
    );
  }
}
