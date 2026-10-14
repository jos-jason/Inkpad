import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/element.dart';
import 'length_field.dart';

/// Make mode → Measurements…: named measurements (thickness, width, …)
/// that sizes can be typed with. Shapes sized with them follow when they
/// change.
Future<void> showMeasurementsDialog(BuildContext context, DrawingController c) => showDialog<void>(
      context: context,
      builder: (context) => _MeasurementsDialog(controller: c),
    );

class _Row {
  final String original; // the name it had ('' for a new one)
  final TextEditingController name, expression;
  bool isNumber;
  String unit;

  _Row(MakeVariable v, {bool isNew = false})
      : original = isNew ? '' : v.name,
        name = TextEditingController(text: v.name),
        expression = TextEditingController(text: v.expression),
        isNumber = v.isNumber,
        unit = v.unit;
}

class _MeasurementsDialog extends StatefulWidget {
  final DrawingController controller;

  const _MeasurementsDialog({required this.controller});

  @override
  State<_MeasurementsDialog> createState() => _MeasurementsDialogState();
}

class _MeasurementsDialogState extends State<_MeasurementsDialog> {
  DrawingController get c => widget.controller;
  late final List<_Row> _rows = [for (final v in c.drawing.variables) _Row(v)];

  @override
  void dispose() {
    for (final r in _rows) {
      r.name.dispose();
      r.expression.dispose();
    }
    super.dispose();
  }

  String get _unit => c.drawing.lengths.unit;

  /// The measurements as typed (each length in the drawing's unit when its
  /// text was changed).
  List<MakeVariable> get _variables => [
        for (final r in _rows)
          MakeVariable(name: r.name.text.trim(), expression: r.expression.text.trim(), unit: r.unit, isNumber: r.isNumber),
      ];

  /// What's wrong with row [i], or null.
  String? _problem(int i, List<MakeVariable> all) {
    final v = all[i];
    if (v.name.isEmpty) return 'Give it a name';
    if (!MakeVariable.validName(v.name)) {
      return MakeVariable.reserved.contains(v.name.toLowerCase()) ? 'That name is a unit' : 'Letters, digits and _ only, starting with a letter';
    }
    for (var j = 0; j < i; j++) {
      if (all[j].name.toLowerCase() == v.name.toLowerCase()) return 'Already used';
    }
    if (v.expression.isEmpty) return 'Give it a value';
    if (VariableScope(all).lookup(v.name) == null) return 'Can\'t work this out';
    return null;
  }

  String _value(MakeVariable v, List<MakeVariable> all) {
    final r = VariableScope(all).lookup(v.name);
    if (r == null) return '';
    if (!r.length) {
      var s = r.value.toStringAsFixed(4);
      s = s.replaceFirst(RegExp(r'\.?0+$'), '');
      return '= $s';
    }
    return '= ${c.drawing.lengths.format(r.value)}';
  }

  void _add() {
    var n = _rows.length + 1;
    final taken = {for (final r in _rows) r.name.text.toLowerCase()};
    var name = _rows.isEmpty ? 'thickness' : 'size$n';
    while (taken.contains(name)) {
      name = 'size${++n}';
    }
    final value = _rows.isEmpty ? c.drawing.lengths.format(c.drawing.materialThickness, withUnit: false) : '';
    setState(() => _rows.add(_Row(MakeVariable(name: name, expression: value, unit: _unit), isNew: true)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _variables;
    final problems = [for (var i = 0; i < all.length; i++) _problem(i, all)];
    return AlertDialog(
      title: const Text('Measurements'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'Name the sizes your design depends on, then type their names in any size box: '
              '"width/2 - thickness", "2 thickness + 3mm". Shapes sized that way follow when a measurement changes. '
              'Sizes typed with names are marked ƒ.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final (i, r) in _rows.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 130,
                    child: TextField(
                      controller: r.name,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: 'Name',
                        border: const OutlineInputBorder(),
                        errorText: problems[i] != null && problems[i] != 'Can\'t work this out' && problems[i] != 'Give it a value' ? problems[i] : null,
                        errorMaxLines: 2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: r.expression,
                      // Plain numbers are in the unit the drawing is in now.
                      onChanged: (_) => setState(() => r.unit = _unit),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: r.isNumber ? 'Number' : 'Length',
                        border: const OutlineInputBorder(),
                        suffixText: problems[i] == null ? _value(all[i], all) : null,
                        errorText: problems[i] == 'Can\'t work this out' || problems[i] == 'Give it a value' ? problems[i] : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'A plain number (a count) rather than a length',
                    child: FilterChip(
                      label: const Text('#'),
                      selected: r.isNumber,
                      onSelected: (v) => setState(() => r.isNumber = v),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => setState(() => _rows.removeAt(i)),
                  ),
                ]),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add measurement')),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: problems.any((p) => p != null)
              ? null
              : () {
                  final renames = {
                    for (final (i, r) in _rows.indexed)
                      if (r.original.isNotEmpty && r.original != all[i].name) r.original: all[i].name,
                  };
                  c.setVariables(all, renames: renames);
                  Navigator.pop(context);
                },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Make mode → Pin to Shape…: keeps the selected shapes in place relative
/// to the largest one (e.g. holes 37 mm from a panel's left edge and
/// centred top to bottom), so they follow when it's moved or resized.
Future<void> showPinDialog(BuildContext context, DrawingController c) => showDialog<void>(
      context: context,
      builder: (context) => _PinDialog(controller: c),
    );

class _PinDialog extends StatefulWidget {
  final DrawingController controller;

  const _PinDialog({required this.controller});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  DrawingController get c => widget.controller;

  late final InkElement target = c.pinTarget!;
  late final InkElement first = c.orderedSelection.firstWhere((e) => !identical(e, target));
  late final int others = c.selection.length - 1;

  // Start from the pin the first shape already has, if any.
  late PinSide? _h = first.pin?.target == target.id ? first.pin!.horizontal : PinSide.start;
  late PinSide? _v = first.pin?.target == target.id ? first.pin!.vertical : PinSide.start;

  /// Typed distances (null: each keeps the distance it's at), and their
  /// formulas when typed with names.
  double? _dx, _dy;
  String? _dxText, _dyText;

  double _current(PinSide side, bool horizontal) {
    final o = first.bounds, t = target.bounds;
    return horizontal ? Pin.distance(side, o.left, o.right, t.left, t.right) : Pin.distance(side, o.top, o.bottom, t.top, t.bottom);
  }

  void _typed(bool horizontal, double v, String? text) => setState(() {
        if (horizontal) {
          _dx = v;
          _dxText = text;
        } else {
          _dy = v;
          _dyText = text;
        }
      });

  Widget _direction(String title, bool horizontal) {
    final side = horizontal ? _h : _v;
    final labels = horizontal ? const ['From left', 'Centred', 'From right'] : const ['From top', 'Centred', 'From bottom'];
    final typed = horizontal ? _dx : _dy;
    final lengths = c.drawing.lengths;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      SegmentedButton<PinSide?>(
        showSelectedIcon: false,
        segments: [
          const ButtonSegment(value: null, label: Text('Free')),
          for (final (i, s) in PinSide.values.indexed) ButtonSegment(value: s, label: Text(labels[i])),
        ],
        selected: {side},
        onSelectionChanged: (v) => setState(() {
          if (horizontal) {
            _h = v.first;
            _dx = _dxText = null;
          } else {
            _v = v.first;
            _dy = _dyText = null;
          }
        }),
      ),
      if (side != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            LengthField(
              key: ValueKey('$horizontal$side'),
              label: side == PinSide.center ? 'Off centre' : 'Distance',
              value: typed ?? _current(side, horizontal),
              lengths: lengths,
              width: 150,
              formula: horizontal ? _dxText : _dyText,
              onChanged: (v) => _typed(horizontal, v, null),
              onFormula: (text, v) => _typed(horizontal, v, text),
            ),
            const SizedBox(width: 10),
            if (others > 1 && typed == null)
              Expanded(child: Text('Each keeps its own distance', style: Theme.of(context).textTheme.bodySmall)),
          ]),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final lengths = c.drawing.lengths;
    final t = target.bounds;
    final hasPins = c.selectionHasPins;
    return AlertDialog(
      title: const Text('Pin to Shape'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              '${others == 1 ? 'The smaller shape stays' : 'The $others smaller shapes stay'} in place on the largest '
              '(${lengths.format(t.width)} × ${lengths.format(t.height)}), following it when it moves or changes size. '
              'Distances can use measurement names.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            _direction('Left to right', true),
            const SizedBox(height: 14),
            _direction('Top to bottom', false),
          ]),
        ),
      ),
      actions: [
        if (hasPins)
          TextButton(
            onPressed: () {
              c.unpinSelection();
              Navigator.pop(context);
            },
            child: const Text('Unpin'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _h == null && _v == null
              ? null
              : () {
                  c.pinSelection(horizontal: _h, vertical: _v, dx: _dx, dy: _dy, dxText: _dxText, dyText: _dyText);
                  Navigator.pop(context);
                },
          child: const Text('Pin'),
        ),
      ],
    );
  }
}
