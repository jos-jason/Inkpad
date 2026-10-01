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
            _FillEditor(controller: c),
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

enum _FillKind { solid, linear, radial }

/// Solid / linear / radial fill editor. Ported in spirit from Inkpad's
/// WDFillController and WDGradientController: tap a stop on the gradient
/// bar, then a swatch to recolor it.
class _FillEditor extends StatefulWidget {
  final DrawingController controller;

  const _FillEditor({required this.controller});

  @override
  State<_FillEditor> createState() => _FillEditorState();
}

class _FillEditorState extends State<_FillEditor> {
  int _stop = 0;

  DrawingController get c => widget.controller;

  void _apply(InkPaint? paint) {
    c.fillPaint = paint;
    c.applyStyleToSelection(fill: true);
    c.changed();
  }

  void _setKind(_FillKind kind) {
    final paint = c.fillPaint;
    if (kind == _FillKind.solid) {
      _apply(paint is InkGradient ? paint.stops[_stop.clamp(0, paint.stops.length - 1)].color : paint);
      return;
    }
    final type = kind == _FillKind.linear ? GradientType.linear : GradientType.radial;
    if (paint is InkGradient) {
      _apply(paint.copyWith(type: type));
    } else {
      // Start from the current color, fading to white (or black, if white).
      final start = (paint as InkColor?) ?? InkColor.black;
      final end = start == InkColor.white ? InkColor.black : InkColor.white;
      _stop = 0;
      _apply(InkGradient.between(start, end, type: type));
    }
  }

  @override
  Widget build(BuildContext context) {
    final paint = c.fillPaint;
    final kind = switch (paint) {
      InkGradient(type: GradientType.linear) => _FillKind.linear,
      InkGradient() => _FillKind.radial,
      _ => _FillKind.solid,
    };
    final gradient = paint is InkGradient ? paint : null;
    if (gradient != null && _stop >= gradient.stops.length) _stop = 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_FillKind>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _FillKind.solid, label: Text('Solid')),
            ButtonSegment(value: _FillKind.linear, label: Text('Linear')),
            ButtonSegment(value: _FillKind.radial, label: Text('Radial')),
          ],
          selected: {kind},
          onSelectionChanged: (s) => _setKind(s.single),
        ),
        const SizedBox(height: 12),
        if (gradient == null)
          _SwatchGrid(selected: paint as InkColor?, onPick: _apply)
        else ...[
          _GradientBar(
            gradient: gradient,
            selected: _stop,
            onSelect: (i) => setState(() => _stop = i),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Reverse',
                icon: const Icon(Icons.swap_horiz),
                onPressed: () {
                  setState(() => _stop = gradient.stops.length - 1 - _stop);
                  _apply(gradient.reversed());
                },
              ),
              IconButton(
                tooltip: 'Add stop',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () {
                  // Halfway between the selected stop and its neighbour.
                  final stops = gradient.stops;
                  final a = stops[_stop], b = stops[_stop < stops.length - 1 ? _stop + 1 : _stop - 1];
                  final offset = (a.offset + b.offset) / 2;
                  final added = [...stops, GradientStop(offset, gradient.colorAt(offset))]
                    ..sort((x, y) => x.offset.compareTo(y.offset));
                  setState(() => _stop = added.indexWhere((s) => s.offset == offset));
                  _apply(gradient.copyWith(stops: added));
                },
              ),
              IconButton(
                tooltip: 'Remove stop',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: gradient.stops.length <= 2
                    ? null
                    : () {
                        final removed = [...gradient.stops]..removeAt(_stop);
                        setState(() => _stop = _stop.clamp(0, removed.length - 1));
                        _apply(gradient.copyWith(stops: removed));
                      },
              ),
              const Spacer(),
              Text('Stop ${_stop + 1} of ${gradient.stops.length}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          _SwatchGrid(
            selected: gradient.stops[_stop].color,
            allowNone: false,
            onPick: (color) => _apply(gradient.withStopColor(_stop, color!)),
          ),
        ],
      ],
    );
  }
}

/// The gradient with a marker per stop; tap a marker to select it.
class _GradientBar extends StatelessWidget {
  final InkGradient gradient;
  final int selected;
  final ValueChanged<int> onSelect;

  const _GradientBar({required this.gradient, required this.selected, required this.onSelect});

  static const _marker = 22.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth - _marker;
      return SizedBox(
        height: 52,
        child: Stack(
          children: [
            Positioned(
              left: _marker / 2,
              right: _marker / 2,
              top: 0,
              height: 24,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: scheme.outline),
                  gradient: LinearGradient(
                    colors: [for (final s in gradient.stops) s.color.toColor()],
                    stops: [for (final s in gradient.stops) s.offset],
                  ),
                ),
              ),
            ),
            for (final (i, stop) in gradient.stops.indexed)
              Positioned(
                left: stop.offset * width,
                top: 26,
                child: Semantics(
                  button: true,
                  selected: i == selected,
                  label: 'Gradient stop ${i + 1}',
                  child: GestureDetector(
                    onTap: () => onSelect(i),
                    child: Container(
                      width: _marker,
                      height: _marker,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: stop.color.toColor(),
                        border: Border.all(
                          color: i == selected ? scheme.primary : scheme.outline,
                          width: i == selected ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}

class _SwatchGrid extends StatelessWidget {
  final InkColor? selected;
  final ValueChanged<InkColor?> onPick;
  final bool allowNone;

  const _SwatchGrid({required this.selected, required this.onPick, this.allowNone = true});

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
      children: [if (allowNone) swatch(null), ..._swatches.map(swatch)],
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
      subtitle: Text('${layer.elements.length} object${layer.elements.length == 1 ? '' : 's'}'),
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
