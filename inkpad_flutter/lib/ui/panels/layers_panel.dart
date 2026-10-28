import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/drawing.dart';
import '../chrome/chrome.dart';
import '../file_actions.dart';

/// Layer list: show/hide, lock, highlight color, drag to reorder, and the
/// active layer's opacity. Ported in spirit from Inkpad's WDLayerController.
class LayersPanel extends StatelessWidget {
  final DrawingController controller;

  const LayersPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final layers = c.drawing.layers;
        final active = c.drawing.activeLayer;
        // Top layer first, as in Inkpad. Row index r is layer n - 1 - r.
        final n = layers.length;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverHeader(
              'Layers',
              leading: IconButton.filledTonal(
                tooltip: 'Delete layer',
                icon: const Icon(Icons.delete_outline),
                onPressed: n > 1 ? c.deleteActiveLayer : null,
              ),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: 'Duplicate layer', icon: const Icon(Icons.library_add_outlined), onPressed: c.duplicateActiveLayer),
                IconButton(tooltip: 'Add layer', icon: const Icon(Icons.add), onPressed: c.addLayer),
              ]),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: n,
                // onReorderItem already adjusts `to` for the removed row.
                onReorderItem: (from, to) => c.moveLayer(n - 1 - from, n - 1 - to),
                itemBuilder: (context, r) {
                  final i = n - 1 - r;
                  return _LayerRow(key: ValueKey(layers[i]), controller: c, index: i, row: r);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: SteppedSlider(
                value: active.opacity * 100,
                min: 0,
                max: 100,
                step: 1,
                format: (v) => '${v.round()}%',
                onChangeStart: c.checkpoint,
                onChanged: (v) => c.setLayerOpacity(v.roundToDouble() / 100, record: false),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LayerRow extends StatelessWidget {
  final DrawingController controller;
  final int index, row;

  const _LayerRow({super.key, required this.controller, required this.index, required this.row});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final layer = c.drawing.layers[index];
    final isActive = c.drawing.activeLayerIndex == index;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: isActive ? scheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: () => c.activateLayer(index),
        onDoubleTap: () => _rename(context),
        onLongPress: () => _rename(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 8, 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(layer.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                Text('${(layer.opacity * 100).round()}%', style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            IconButton(
              tooltip: layer.visible ? 'Hide layer' : 'Show layer',
              icon: Icon(layer.visible ? Icons.check_circle_outline : Icons.radio_button_unchecked, color: scheme.primary),
              onPressed: () => c.updateLayer(index, (l) => l.visible = !l.visible),
            ),
            IconButton(
              tooltip: layer.locked ? 'Unlock layer' : 'Lock layer',
              icon: Icon(layer.locked ? Icons.lock_outline : Icons.lock_open, color: scheme.primary),
              onPressed: () => c.updateLayer(index, (l) => l.locked = !l.locked),
            ),
            Tooltip(
              message: 'Highlight color',
              child: InkWell(
                onTap: () {
                  // Cycle through the highlight palette.
                  const colors = InkLayer.highlightColors;
                  final next = colors[(colors.indexOf(layer.highlightColor) + 1) % colors.length];
                  c.updateLayer(index, (l) => l.highlightColor = next);
                },
                child: Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: layer.highlightColor.toColor(),
                ),
              ),
            ),
            ReorderableDragStartListener(
              index: row,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_handle, color: Colors.black38),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final layer = controller.drawing.layers[index];
    final name = await promptForText(context, title: 'Rename layer', initial: layer.name);
    if (name != null && name.trim().isNotEmpty) controller.updateLayer(index, (l) => l.name = name.trim());
  }
}
