import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/element.dart';
import '../../model/units.dart';
import '../chrome/chrome.dart';
import 'length_field.dart';

/// Make mode: the selection's position and size as numbers you can type,
/// plus a live shape's own settings (corner radius, sides, …).
class NumbersBar extends StatefulWidget {
  final DrawingController controller;

  const NumbersBar({super.key, required this.controller});

  @override
  State<NumbersBar> createState() => _NumbersBarState();
}

class _NumbersBarState extends State<NumbersBar> {
  static bool _keepProportions = false;

  DrawingController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final m = c.measure;
    if (m == null) return const SizedBox.shrink();
    final lengths = c.drawing.lengths;
    final livePath = c.singleLiveShape;
    final live = livePath?.live;
    final theme = Theme.of(context);

    Widget field(String label, double value, ValueChanged<double> onChanged, {double width = 104}) =>
        Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: LengthField(label: label, value: value, lengths: lengths, onChanged: onChanged, width: width));

    Widget number(String label, double value, ValueChanged<double> onChanged, {String Function(double)? format, double? Function(String)? parse, double width = 72}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: LengthField(
            label: label,
            value: value,
            lengths: lengths,
            width: width,
            format: format ?? (v) => v.round().toString(),
            parse: parse ?? (t) => parseDegrees(t),
            onChanged: onChanged,
          ),
        );

    final isLine = live?.kind == LiveKind.line;
    final children = <Widget>[
      field('X', m.bounds.left, (v) => c.moveSelectionTo(x: v)),
      field('Y', m.bounds.top, (v) => c.moveSelectionTo(y: v)),
      field(isLine ? 'Length' : 'W', m.width, (v) => c.resizeSelection(width: v, keepProportions: _keepProportions && !isLine)),
      if (!isLine) ...[
        IconButton(
          tooltip: _keepProportions ? 'Proportions locked' : 'Keep proportions',
          isSelected: _keepProportions,
          icon: Icon(_keepProportions ? Icons.link : Icons.link_off, size: 20),
          onPressed: () => setState(() => _keepProportions = !_keepProportions),
        ),
        field('H', m.height, (v) => c.resizeSelection(height: v, keepProportions: _keepProportions)),
      ],
      if (live != null)
        number('Angle', live.angle, c.setLiveAngle, format: formatDegrees),
      if (live?.kind == LiveKind.rectangle)
        field('Corner', live!.cornerRadius, (v) => c.setLiveShape(livePath!, live.copyWith(cornerRadius: v.clamp(0, double.infinity))), width: 96),
      if (live?.kind == LiveKind.polygon)
        number('Sides', live!.sides.toDouble(), (v) => c.setLiveShape(livePath!, live.copyWith(sides: v.round().clamp(3, 100)))),
      if (live?.kind == LiveKind.star) ...[
        number('Points', live!.sides.toDouble(), (v) => c.setLiveShape(livePath!, live.copyWith(sides: v.round().clamp(3, 100)))),
        number('Inner %', live.innerRatio * 100, (v) => c.setLiveShape(livePath!, live.copyWith(innerRatio: (v / 100).clamp(0.05, 0.95)))),
      ],
    ];

    return Pill(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(mainAxisSize: MainAxisSize.min, children: children)),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
          child: Text(
            live != null
                ? '${_kindName(live.kind)} · keeps its dimensions'
                : c.selection.length == 1
                    ? 'Size of its outline'
                    : '${c.selection.length} items · size of them together',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }

  static String _kindName(LiveKind k) => switch (k) {
        LiveKind.rectangle => 'Rectangle',
        LiveKind.ellipse => 'Ellipse',
        LiveKind.polygon => 'Polygon',
        LiveKind.star => 'Star',
        LiveKind.line => 'Line',
      };
}
