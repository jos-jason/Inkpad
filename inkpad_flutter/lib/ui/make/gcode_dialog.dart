import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../export/gcode.dart';
import '../../model/drawing.dart';
import '../file_actions.dart';
import 'length_field.dart';

/// Share → Export G-code…: feeds, speeds and tabs, a preview of the
/// toolpaths you can play through, and Save.
Future<void> showGcodeDialog(BuildContext context, InkDrawing drawing, String name) => showDialog<void>(
      context: context,
      builder: (context) => _GcodeDialog(drawing: drawing, name: name),
    );

class _GcodeDialog extends StatefulWidget {
  final InkDrawing drawing;
  final String name;

  const _GcodeDialog({required this.drawing, required this.name});

  @override
  State<_GcodeDialog> createState() => _GcodeDialogState();
}

class _GcodeDialogState extends State<_GcodeDialog> {
  late GcodeProgram _program = _make();
  double _progress = 1;

  InkDrawing get d => widget.drawing;
  CamSettings get cam => d.cam;

  GcodeProgram _make() => makeGcode(d, cam, title: widget.name);

  void _change(void Function() f) {
    setState(() {
      f();
      _program = _make();
    });
  }

  @override
  Widget build(BuildContext context) {
    final lengths = d.lengths;
    final theme = Theme.of(context);
    final speedUnit = d.units == 'in' ? 'in/min' : 'mm/min';
    final toSpeed = d.units == 'in' ? 1 / 25.4 : 1.0;
    Widget number(String label, double value, ValueChanged<double> set, {String suffix = '', double factor = 1}) => LengthField(
          label: label,
          value: value * factor,
          lengths: lengths,
          width: 130,
          format: (v) => '${_trim(v)}${suffix.isEmpty ? '' : ' $suffix'}',
          parse: (t) => parseDegrees(t.replaceAll(RegExp(r'[a-zA-Z/%]'), '')),
          onChanged: (v) => _change(() => set(v / factor)),
        );
    Widget length(String label, double value, ValueChanged<double> set) =>
        LengthField(label: label, value: value, lengths: lengths, width: 130, onChanged: (v) => _change(() => set(v)));

    final p = _program;
    return AlertDialog(
      title: const Text('Export G-code'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'For CNC routers with GRBL and similar controllers (the Shaper Origin uses the SVG export instead). '
              'Bit ${lengths.format(d.bitDiameter)} from Settings. Origin: the page\'s bottom-left corner, Z0 on top of the material.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: [
              number('Feed', cam.feed, (v) => cam.feed = v, suffix: speedUnit, factor: toSpeed),
              number('Plunge', cam.plunge, (v) => cam.plunge = v, suffix: speedUnit, factor: toSpeed),
              number('Spindle', cam.spindle.toDouble(), (v) => cam.spindle = v.round(), suffix: 'rpm'),
              length('Depth per pass', cam.stepDown, (v) => cam.stepDown = math.max(v, 0.1)),
              length('Safe height', cam.safeHeight, (v) => cam.safeHeight = math.max(v, 0)),
              number('Pocket step-over', cam.stepOver * 100, (v) => cam.stepOver = (v / 100).clamp(0.05, 0.95), suffix: '%'),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Checkbox(value: cam.tabs, onChanged: (v) => _change(() => cam.tabs = v ?? true)),
              const Text('Holding tabs on through-cuts'),
              const Spacer(),
              Checkbox(value: cam.climb, onChanged: (v) => _change(() => cam.climb = v ?? false)),
              const Text('Climb milling'),
            ]),
            if (cam.tabs)
              Wrap(spacing: 10, runSpacing: 10, children: [
                number('Tabs per part', cam.tabCount.toDouble(), (v) => cam.tabCount = math.max(1, v.round())),
                length('Tab width', cam.tabWidth, (v) => cam.tabWidth = v),
                length('Tab height', cam.tabHeight, (v) => cam.tabHeight = v),
              ]),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: d.width / d.height,
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: theme.colorScheme.outlineVariant), color: Colors.white),
                child: CustomPaint(painter: _ToolpathPainter(d, p, _progress)),
              ),
            ),
            Slider(value: _progress, onChanged: (v) => setState(() => _progress = v)),
            Text(
              p.moves.length <= 2
                  ? 'Nothing to cut: give shapes a cut type other than Guide.'
                  : 'Cutting ${lengths.format(p.cutLength)}, about ${_time(p.minutes)}. Drag the slider to play the job through.',
              style: theme.textTheme.bodySmall,
            ),
            for (final n in p.notes.toSet()) Text('• $n', style: TextStyle(color: theme.colorScheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          onPressed: p.moves.length <= 2
              ? null
              : () async {
                  await saveFile(context, '${widget.name}.nc', utf8.encode(p.code), 'text/plain', 'nc');
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('Save G-code'),
        ),
      ],
    );
  }

  static String _trim(double v) {
    var s = v.toStringAsFixed(1);
    if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
    return s;
  }

  static String _time(double minutes) {
    if (minutes < 1) return '${(minutes * 60).round()} s';
    if (minutes < 60) return '${minutes.round()} min';
    return '${(minutes / 60).floor()} h ${(minutes % 60).round()} min';
  }
}

/// The page with the tool's moves: cuts in orange (darker deeper), moves
/// between cuts in gray, up to [progress] of the job.
class _ToolpathPainter extends CustomPainter {
  final InkDrawing d;
  final GcodeProgram p;
  final double progress;

  _ToolpathPainter(this.d, this.p, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / d.width;
    canvas.scale(s);
    final last = (p.moves.length * progress).round().clamp(0, p.moves.length);
    var depth = 0.0;
    for (final m in p.moves) {
      depth = math.min(depth, m.z);
    }
    final rapid = Paint()
      ..color = const Color(0x55808080)
      ..strokeWidth = 0.6 / s;
    for (var i = 1; i < last; i++) {
      final a = p.moves[i - 1], b = p.moves[i];
      if (b.rapid) {
        canvas.drawLine(a.at, b.at, rapid);
      } else {
        final t = depth == 0 ? 1.0 : (b.z / depth).clamp(0.2, 1.0);
        canvas.drawLine(
          a.at,
          b.at,
          Paint()
            ..color = Color.lerp(const Color(0xFFFFC08A), const Color(0xFFD9480F), t)!
            ..strokeWidth = 1.2 / s,
        );
      }
    }
    if (last > 0 && last <= p.moves.length) {
      final tool = p.moves[last - 1];
      canvas.drawCircle(tool.at, d.bitDiameter / 2, Paint()..color = const Color(0x882B6CB0));
    }
  }

  @override
  bool shouldRepaint(_ToolpathPainter old) => old.p != p || old.progress != progress;
}
