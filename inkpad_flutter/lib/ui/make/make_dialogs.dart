import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../geometry/make_ops.dart';
import '../../model/units.dart';
import 'length_field.dart';

/// A small dialog with a title, rows of fields, and an action button.
Future<bool> _dialog(BuildContext context, {required String title, required String action, required Widget Function(StateSetter) body}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 380, child: SingleChildScrollView(child: body(setState))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ),
  );
  return ok == true;
}

Widget _row(String label, Widget field, {String? help}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label),
            if (help != null) Text(help, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ]),
        ),
        field,
      ]),
    );

Widget _count(int value, ValueChanged<int> onChanged, LengthFormat lengths, {int min = 1}) => LengthField(
      value: value.toDouble(),
      lengths: lengths,
      width: 90,
      format: (v) => v.round().toString(),
      parse: (t) => parseDegrees(t),
      onChanged: (v) => onChanged(math.max(min, v.round())),
    );

/// Path → Offset Path…: grow or shrink the selection by a distance.
Future<void> showOffsetDialog(BuildContext context, DrawingController c) async {
  final lengths = c.drawing.lengths;
  var distance = 3 * 72 / 25.4;
  var round = true;
  final ok = await _dialog(
    context,
    title: 'Offset Path',
    action: 'Offset',
    body: (setState) => Column(mainAxisSize: MainAxisSize.min, children: [
      _row('Distance', LengthField(value: distance, lengths: lengths, width: 130, onChanged: (v) => setState(() => distance = v)),
          help: 'Positive grows, negative shrinks'),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: const [ButtonSegment(value: true, label: Text('Round corners')), ButtonSegment(value: false, label: Text('Sharp corners'))],
        selected: {round},
        onSelectionChanged: (s) => setState(() => round = s.single),
      ),
      const SizedBox(height: 8),
      const Text('A new shape is added; the original stays.', style: TextStyle(fontSize: 12)),
    ]),
  );
  if (ok) c.offsetPaths(distance, round: round);
}

/// Edit → Repeat…: copies in a grid or around a center.
Future<void> showRepeatDialog(BuildContext context, DrawingController c) async {
  final b = c.selectionBounds;
  if (b == null) return;
  final lengths = c.drawing.lengths;
  var around = false;
  var columns = 3, rows = 1;
  var pitchX = b.width + 10 * 72 / 25.4, pitchY = b.height + 10 * 72 / 25.4;
  var count = 6;
  double? step;
  var cx = b.center.dx, cy = b.center.dy + b.height * 2;
  final ok = await _dialog(
    context,
    title: 'Repeat',
    action: 'Repeat',
    body: (setState) => Column(mainAxisSize: MainAxisSize.min, children: [
      SegmentedButton<bool>(
        segments: const [ButtonSegment(value: false, label: Text('Grid')), ButtonSegment(value: true, label: Text('Around a center'))],
        selected: {around},
        onSelectionChanged: (s) => setState(() => around = s.single),
      ),
      const SizedBox(height: 12),
      if (!around) ...[
        _row('Columns', _count(columns, (v) => setState(() => columns = v), lengths)),
        _row('Rows', _count(rows, (v) => setState(() => rows = v), lengths)),
        _row('Across', LengthField(value: pitchX, lengths: lengths, width: 130, onChanged: (v) => setState(() => pitchX = v)), help: 'Center to center'),
        _row('Down', LengthField(value: pitchY, lengths: lengths, width: 130, onChanged: (v) => setState(() => pitchY = v)), help: 'Center to center'),
      ] else ...[
        _row('Copies in all', _count(count, (v) => setState(() => count = v), lengths, min: 2)),
        _row(
          'Angle between',
          LengthField(
            value: step ?? 360 / count,
            lengths: lengths,
            width: 90,
            format: formatDegrees,
            parse: parseDegrees,
            onChanged: (v) => setState(() => step = v),
          ),
        ),
        _row('Center X', LengthField(value: cx, lengths: lengths, width: 130, onChanged: (v) => setState(() => cx = v))),
        _row('Center Y', LengthField(value: cy, lengths: lengths, width: 130, onChanged: (v) => setState(() => cy = v))),
      ],
    ]),
  );
  if (!ok) return;
  if (around) {
    c.repeatAround(count: count, center: Offset(cx, cy), stepDegrees: step ?? 360 / count);
  } else {
    c.repeatGrid(columns: columns, rows: rows, pitchX: pitchX, pitchY: pitchY);
  }
}

/// Path → Box Maker…: a finger-jointed box from the material thickness.
Future<void> showBoxMakerDialog(BuildContext context, DrawingController c) async {
  final d = c.drawing;
  final lengths = d.lengths;
  final mm = 72 / 25.4;
  var w = 300 * mm, depth = 200 * mm, h = 150 * mm;
  var inside = false;
  var t = d.materialThickness;
  var finger = t * 3;
  var clearance = 0.1 * mm;
  var closedTop = false, dogbones = true;
  final ok = await _dialog(
    context,
    title: 'Box Maker',
    action: 'Make box',
    body: (setState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<bool>(
        segments: const [ButtonSegment(value: false, label: Text('Outside sizes')), ButtonSegment(value: true, label: Text('Inside sizes'))],
        selected: {inside},
        onSelectionChanged: (s) => setState(() => inside = s.single),
      ),
      const SizedBox(height: 8),
      _row('Width', LengthField(value: w, lengths: lengths, width: 130, onChanged: (v) => setState(() => w = v))),
      _row('Depth', LengthField(value: depth, lengths: lengths, width: 130, onChanged: (v) => setState(() => depth = v))),
      _row('Height', LengthField(value: h, lengths: lengths, width: 130, onChanged: (v) => setState(() => h = v))),
      const Divider(),
      _row('Material thickness', LengthField(value: t, lengths: lengths, width: 130, onChanged: (v) => setState(() => t = v))),
      _row('Finger width', LengthField(value: finger, lengths: lengths, width: 130, onChanged: (v) => setState(() => finger = v)),
          help: 'About; edges get an odd number of equal fingers'),
      _row('Fit clearance', LengthField(value: clearance, lengths: lengths, width: 130, onChanged: (v) => setState(() => clearance = v)),
          help: 'Makes fingers this much narrower, for glue'),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Lid (closed top)'), value: closedTop, onChanged: (v) => setState(() => closedTop = v)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Dogbones'),
        subtitle: Text('Relief in inside corners for the ${lengths.format(d.bitDiameter)} bit'),
        value: dogbones,
        onChanged: (v) => setState(() => dogbones = v),
      ),
    ]),
  );
  if (!ok) return;
  final extra = inside ? 2 * t : 0.0;
  final box = BoxMaker(
    width: w + extra,
    depth: depth + extra,
    height: h + (inside ? (closedTop ? 2 * t : t) : 0),
    thickness: t,
    fingerWidth: math.max(finger, t),
    clearance: clearance,
    closedTop: closedTop,
  );
  c.makeBox(box, origin: Offset(10 * mm, 10 * mm), dogbones: dogbones);
}
