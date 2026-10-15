import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../make/length_field.dart';

/// A named page size, in points.
class PagePreset {
  final String name;
  final double width, height;

  const PagePreset(this.name, this.width, this.height);
}

const _mm = 72 / 25.4;

/// Common page and sheet sizes (portrait; the swap button turns them).
const pagePresets = <(String, List<PagePreset>)>[
  ('Paper', [
    PagePreset('Letter', 612, 792),
    PagePreset('Legal', 612, 1008),
    PagePreset('Tabloid', 792, 1224),
    PagePreset('A5', 148 * _mm, 210 * _mm),
    PagePreset('A4', 210 * _mm, 297 * _mm),
    PagePreset('A3', 297 * _mm, 420 * _mm),
  ]),
  ('Screen', [
    PagePreset('iPad (Inkpad)', 768, 1024),
    PagePreset('Square 1080', 1080, 1080),
    PagePreset('HD 1920 × 1080', 1080, 1920),
  ]),
  ('Sheet goods', [
    PagePreset('600 × 400 mm', 400 * _mm, 600 * _mm),
    PagePreset('2 × 2 ft', 1728, 1728),
    PagePreset('2 × 4 ft', 1728, 3456),
    PagePreset('4 × 8 ft', 3456, 6912),
    PagePreset('1220 × 2440 mm', 1220 * _mm, 2440 * _mm),
    PagePreset('1250 × 2500 mm', 1250 * _mm, 2500 * _mm),
  ]),
];

/// Settings → Canvas Size…: the page's width and height (typed, or from a
/// preset), which side the artwork stays with, or fit to the artwork.
Future<void> showCanvasSizeDialog(BuildContext context, DrawingController c) => showDialog<void>(
      context: context,
      builder: (context) => _CanvasSizeDialog(controller: c),
    );

class _CanvasSizeDialog extends StatefulWidget {
  final DrawingController controller;

  const _CanvasSizeDialog({required this.controller});

  @override
  State<_CanvasSizeDialog> createState() => _CanvasSizeDialogState();
}

class _CanvasSizeDialogState extends State<_CanvasSizeDialog> {
  DrawingController get c => widget.controller;
  late double _w = c.drawing.width, _h = c.drawing.height;
  Alignment _anchor = Alignment.topLeft;
  late double _margin = c.drawing.makeMode ? 10 * _mm : 18;

  void _preset(PagePreset p) {
    // Keep the current orientation.
    final landscape = _w > _h;
    setState(() {
      _w = landscape ? math.max(p.width, p.height) : math.min(p.width, p.height);
      _h = landscape ? math.min(p.width, p.height) : math.max(p.width, p.height);
    });
  }

  Widget _anchorGrid(ColorScheme colors) => SizedBox(
        width: 84,
        height: 84,
        child: GridView.count(
          crossAxisCount: 3,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 3,
          crossAxisSpacing: 3,
          children: [
            for (final y in const [-1.0, 0.0, 1.0])
              for (final x in const [-1.0, 0.0, 1.0])
                Tooltip(
                  message: 'Keep the artwork ${_anchorName(x, y)}',
                  child: InkWell(
                    onTap: () => setState(() => _anchor = Alignment(x, y)),
                    child: Container(
                      decoration: BoxDecoration(
                        color: _anchor == Alignment(x, y) ? colors.primary : colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      );

  static String _anchorName(double x, double y) {
    if (x == 0 && y == 0) return 'in the centre';
    final v = y < 0 ? 'top' : y > 0 ? 'bottom' : '';
    final h = x < 0 ? 'left' : x > 0 ? 'right' : '';
    return 'at the ${[v, h].where((s) => s.isNotEmpty).join('-')}';
  }

  @override
  Widget build(BuildContext context) {
    final lengths = c.drawing.lengths;
    final theme = Theme.of(context);
    final art = c.artworkBounds;
    return AlertDialog(
      title: const Text('Canvas Size'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              LengthField(label: 'Width', value: _w, lengths: lengths, width: 130, onChanged: (v) => setState(() => _w = math.max(v, 1))),
              IconButton(
                tooltip: 'Swap width and height',
                icon: const Icon(Icons.swap_horiz),
                onPressed: () => setState(() {
                  final w = _w;
                  _w = _h;
                  _h = w;
                }),
              ),
              LengthField(label: 'Height', value: _h, lengths: lengths, width: 130, onChanged: (v) => setState(() => _h = math.max(v, 1))),
              const Spacer(),
              PopupMenuButton<PagePreset>(
                tooltip: 'Sizes',
                icon: const Icon(Icons.list_alt),
                onSelected: _preset,
                itemBuilder: (context) => [
                  for (final (group, presets) in pagePresets) ...[
                    PopupMenuItem<PagePreset>(enabled: false, height: 28, child: Text(group, style: theme.textTheme.labelSmall)),
                    for (final p in presets)
                      PopupMenuItem(
                        value: p,
                        child: Text('${p.name}  ·  ${lengths.format(p.width)} × ${lengths.format(p.height)}'),
                      ),
                  ],
                ],
              ),
            ]),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _anchorGrid(theme.colorScheme),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'The artwork stays ${_anchorName(_anchor.x, _anchor.y)} of the page; the page grows or shrinks around it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ]),
            if (art != null) ...[
              const Divider(height: 28),
              Row(children: [
                LengthField(label: 'Margin', value: _margin, lengths: lengths, width: 120, onChanged: (v) => setState(() => _margin = math.max(v, 0))),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.fit_screen_outlined),
                  label: const Text('Fit to Artwork'),
                  onPressed: () {
                    c.fitCanvasToArtwork(margin: _margin);
                    Navigator.pop(context);
                  },
                ),
              ]),
              const SizedBox(height: 4),
              Text('The artwork is ${lengths.format(art.width)} × ${lengths.format(art.height)}.', style: theme.textTheme.bodySmall),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            c.resizeCanvas(_w, _h, anchor: _anchor);
            Navigator.pop(context);
          },
          child: const Text('Resize'),
        ),
      ],
    );
  }
}
