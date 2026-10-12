import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/effects.dart';
import '../chrome/chrome.dart';
import '../chrome/color_editor.dart';

/// Shadow, opacity and blend mode for the selection or new shapes.
/// Ported from Inkpad's WDShadowController.
class ShadowPanel extends StatefulWidget {
  final DrawingController controller;

  const ShadowPanel({super.key, required this.controller});

  @override
  State<ShadowPanel> createState() => _ShadowPanelState();
}

class _ShadowPanelState extends State<ShadowPanel> {
  bool _choosingBlendMode = false;

  DrawingController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.topCenter,
        child: _choosingBlendMode ? _blendModes(context) : _main(context),
      ),
    );
  }

  Widget _main(BuildContext context) {
    final shadow = c.shadow;
    final on = shadow != null;
    final s = shadow ?? c.lastShadow;
    // While a control moves, only the first change is recorded for undo.
    void live(InkShadow v) => c.setShadow(v, record: false);

    final controls = Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ColorEditor(color: s.color, onChangeStart: c.checkpoint, onChanged: (color) => live(s.copyWith(color: color))),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
        child: Row(children: [
          AngleDial(
            angle: s.angle,
            onChangeStart: c.checkpoint,
            onChanged: (a) => live(s.copyWith(angle: a)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(children: [
              SteppedSlider(
                label: 'Offset',
                value: s.offset.clamp(0, 50),
                min: 0,
                max: 50,
                step: 1,
                format: (v) => '${v.round()} pt',
                onChangeStart: c.checkpoint,
                onChanged: (v) => live(s.copyWith(offset: v.roundToDouble())),
              ),
              SteppedSlider(
                label: 'Blur',
                value: s.radius.clamp(0, 50),
                min: 0,
                max: 50,
                step: 1,
                format: (v) => '${v.round()} pt',
                onChangeStart: c.checkpoint,
                onChanged: (v) => live(s.copyWith(radius: v.roundToDouble())),
              ),
            ]),
          ),
        ]),
      ),
    ]);

    return Column(
      key: const ValueKey('main'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopoverHeader(
          'Shadow',
          trailing: Switch(value: on, onChanged: (v) => c.setShadow(v ? c.lastShadow : null)),
        ),
        // The controls stay visible, dimmed, while the shadow is off.
        IgnorePointer(ignoring: !on, child: Opacity(opacity: on ? 1 : 0.4, child: controls)),
        const Divider(indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: SteppedSlider(
            label: 'Opacity',
            value: c.opacity * 100,
            min: 0,
            max: 100,
            step: 1,
            format: (v) => '${v.round()}%',
            onChangeStart: c.checkpoint,
            onChanged: (v) => c.setOpacity(v.roundToDouble() / 100, record: false),
          ),
        ),
        ListTile(
          title: const Text('Blend Mode'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(c.blendMode.label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const Icon(Icons.chevron_right),
          ]),
          onTap: () => setState(() => _choosingBlendMode = true),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _blendModes(BuildContext context) {
    return Column(
      key: const ValueKey('blend'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopoverHeader(
          'Blend Mode',
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _choosingBlendMode = false),
          ),
          trailing: const SizedBox(width: 48),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final m in InkBlendMode.values)
                ListTile(
                  dense: true,
                  title: Text(m.label),
                  selected: m == c.blendMode,
                  trailing: m == c.blendMode ? const Icon(Icons.check, size: 18) : null,
                  onTap: () {
                    c.setBlendMode(m);
                    setState(() => _choosingBlendMode = false);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A round dial for an angle in degrees (counterclockwise from the right),
/// like the shadow angle control in Inkpad.
class AngleDial extends StatelessWidget {
  final double angle;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final double size;

  const AngleDial({super.key, required this.angle, required this.onChanged, this.onChangeStart, this.size = 72});

  void _set(Offset local) {
    final d = local - Offset(size / 2, size / 2);
    if (d.distance < 2) return;
    var a = -math.atan2(d.dy, d.dx) * 180 / math.pi;
    if (a < 0) a += 360;
    onChanged(a.roundToDouble() % 360);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Semantics(
        label: 'Shadow angle',
        value: '${angle.round()} degrees',
        child: GestureDetector(
          onPanStart: (e) {
            onChangeStart?.call();
            _set(e.localPosition);
          },
          onPanUpdate: (e) => _set(e.localPosition),
          onTapDown: (e) {
            onChangeStart?.call();
            _set(e.localPosition);
          },
          child: CustomPaint(
            size: Size.square(size),
            painter: _DialPainter(angle, scheme.outline, scheme.primary, scheme.surfaceContainerHighest),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text('${angle.round()}°', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _DialPainter extends CustomPainter {
  final double angle;
  final Color rim, hand, face;

  _DialPainter(this.angle, this.rim, this.hand, this.face);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    canvas.drawCircle(c, r, Paint()..color = face);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = rim,
    );
    final a = angle * math.pi / 180;
    final tip = c + Offset(math.cos(a), -math.sin(a)) * (r - 6);
    final line = Paint()
      ..color = hand
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c, tip, line);
    canvas.drawCircle(tip, 5, Paint()..color = hand);
    canvas.drawCircle(c, 3, Paint()..color = hand);
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.angle != angle || old.hand != hand || old.rim != rim || old.face != face;
}
