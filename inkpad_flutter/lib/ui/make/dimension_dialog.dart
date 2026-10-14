import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/constraints.dart';
import '../../model/units.dart';
import 'length_field.dart';

/// The kinds of dimension that fit the picked items, the likeliest first.
List<ConstraintType> dimensionOptions(DrawingController c, List<GeoRef> refs) {
  final kinds = [for (final r in refs) r.kind];
  if (kinds.length == 1) {
    return switch (kinds.single) {
      GeoKind.circle => [ConstraintType.diameter, ConstraintType.radius],
      GeoKind.line => [ConstraintType.distance, ConstraintType.horizontalDistance, ConstraintType.verticalDistance],
      GeoKind.point => [],
    };
  }
  if (kinds.length != 2) return [];
  if (!kinds.contains(GeoKind.line)) {
    return [ConstraintType.distance, ConstraintType.horizontalDistance, ConstraintType.verticalDistance];
  }
  if (kinds.every((k) => k == GeoKind.line)) {
    final a = c.geometryOf(refs[0].element).line(refs[0].index), b = c.geometryOf(refs[1].element).line(refs[1].index);
    if (a == null || b == null) return [];
    final d1 = a.$2 - a.$1, d2 = b.$2 - b.$1;
    final sine = (d1.dx * d2.dy - d1.dy * d2.dx) / (d1.distance * d2.distance);
    return sine.abs() < 1e-3 ? [ConstraintType.distance, ConstraintType.angle] : [ConstraintType.angle];
  }
  return [ConstraintType.distance];
}

String _optionLabel(ConstraintType t, List<GeoRef> refs) => switch (t) {
      ConstraintType.distance => refs.length == 1 ? 'Length' : 'Distance',
      ConstraintType.horizontalDistance => 'Across',
      ConstraintType.verticalDistance => 'Up/down',
      ConstraintType.angle => 'Angle',
      ConstraintType.radius => 'Radius',
      ConstraintType.diameter => 'Diameter',
      _ => t.label,
    };

/// Asks for a new dimension's kind and value, then adds it.
Future<void> showDimensionDialog(BuildContext context, DrawingController c, List<GeoRef> refs) async {
  final options = dimensionOptions(c, refs);
  if (options.isEmpty) {
    c.showHint('Dimensions measure a line, a circle, or between two items.');
    return;
  }
  await showDialog<void>(context: context, builder: (context) => _DimensionDialog(controller: c, refs: refs, options: options));
}

/// Changes an existing dimension's value (or makes it a reference, or
/// deletes it).
Future<void> showDimensionEditDialog(BuildContext context, DrawingController c, SketchConstraint k) =>
    showDialog<void>(context: context, builder: (context) => _DimensionDialog(controller: c, refs: k.refs, options: [k.type], existing: k));

class _DimensionDialog extends StatefulWidget {
  final DrawingController controller;
  final List<GeoRef> refs;
  final List<ConstraintType> options;
  final SketchConstraint? existing;

  const _DimensionDialog({required this.controller, required this.refs, required this.options, this.existing});

  @override
  State<_DimensionDialog> createState() => _DimensionDialogState();
}

class _DimensionDialogState extends State<_DimensionDialog> {
  DrawingController get c => widget.controller;
  late ConstraintType _type = widget.options.first;
  late bool _reference = widget.existing?.reference ?? false;
  double? _value;
  String? _formula;

  @override
  void initState() {
    super.initState();
    final k = widget.existing;
    if (k != null) {
      _value = k.value;
      _formula = k.formula?.text;
    }
  }

  /// The measurement now, for the chosen kind (positive).
  double get _current {
    final m = c.measureConstraint(SketchConstraint(_type, widget.refs));
    return (m ?? 0).abs();
  }

  bool get _angle => _type == ConstraintType.angle;

  void _set(double v, String? formula) => setState(() {
        _value = v;
        _formula = formula;
      });

  @override
  Widget build(BuildContext context) {
    final lengths = c.drawing.lengths;
    final editing = widget.existing != null;
    final value = _value ?? _current;
    return AlertDialog(
      title: Text(editing ? 'Change ${_optionLabel(_type, widget.refs)}' : 'Dimension'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.options.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: SegmentedButton<ConstraintType>(
                showSelectedIcon: false,
                segments: [for (final t in widget.options) ButtonSegment(value: t, label: Text(_optionLabel(t, widget.refs)))],
                selected: {_type},
                onSelectionChanged: (s) => setState(() {
                  _type = s.single;
                  _value = null;
                  _formula = null;
                }),
              ),
            ),
          LengthField(
            key: ValueKey(_type),
            label: _optionLabel(_type, widget.refs),
            value: value,
            lengths: lengths,
            width: 200,
            format: _angle ? (v) => '${LengthFormat(unit: 'pt').format(v, withUnit: false)}°' : null,
            parse: _angle ? parseDegrees : null,
            formula: _formula,
            onFormula: _angle ? null : (text, v) => _set(v, text),
            onChanged: (v) => _set(v, null),
          ),
          const SizedBox(height: 6),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _reference,
            onChanged: (v) => setState(() => _reference = v ?? false),
            title: const Text('Reference only'),
            subtitle: const Text('Shows the measurement without holding it'),
          ),
        ]),
      ),
      actions: [
        if (editing)
          TextButton(
            onPressed: () {
              c.deleteConstraint(widget.existing!);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final k = widget.existing;
            if (k != null) {
              c.setConstraintReference(k, _reference);
              if (!_reference && (_value != null && _value != k.value || _formula != k.formula?.text)) {
                c.setConstraintValue(k, value, formulaText: _formula);
              }
            } else {
              c.constrain(_type, widget.refs, value: _reference ? null : value, formulaText: _reference ? null : _formula, reference: _reference);
            }
            Navigator.pop(context);
          },
          child: Text(editing ? 'Change' : 'Add'),
        ),
      ],
    );
  }
}
