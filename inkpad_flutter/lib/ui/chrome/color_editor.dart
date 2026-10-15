import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/style.dart';

/// Hue / saturation / brightness / alpha sliders with numeric fields and a
/// hex entry. Ported in spirit from Inkpad's WDColorController.
///
/// Calls [onChangeStart] once before a drag (for a single undo step),
/// [onChanged] continuously, and [onChangeEnd] when done.
class ColorEditor extends StatefulWidget {
  final InkColor color;
  final ValueChanged<InkColor> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  const ColorEditor({super.key, required this.color, required this.onChanged, this.onChangeStart, this.onChangeEnd});

  @override
  State<ColorEditor> createState() => _ColorEditorState();
}

class _ColorEditorState extends State<ColorEditor> {
  // HSB is kept here so hue survives passing through grays (which have none).
  late double _h, _s, _b, _a;

  @override
  void initState() {
    super.initState();
    _sync(widget.color, keepHue: false);
  }

  @override
  void didUpdateWidget(ColorEditor old) {
    super.didUpdateWidget(old);
    if (widget.color != _current) _sync(widget.color, keepHue: true);
  }

  void _sync(InkColor c, {required bool keepHue}) {
    if (!keepHue || c.saturation > 0.001) _h = c.hue;
    _s = c.saturation;
    _b = c.brightness;
    _a = c.alpha;
  }

  InkColor get _current => InkColor.hsb(_h, _s, _b, _a);

  void _set({double? h, double? s, double? b, double? a}) {
    setState(() {
      _h = h ?? _h;
      _s = s ?? _s;
      _b = b ?? _b;
      _a = a ?? _a;
    });
    widget.onChanged(_current);
  }

  void _commit(void Function() change) {
    widget.onChangeStart?.call();
    change();
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final hueColors = [for (var i = 0; i <= 6; i++) InkColor.hsb(i * 60.0, 1, 1).toColor()];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(children: [
        _row('H', '${_h.round()}°', 360, _h / 360, (v) => _set(h: v * 360), (v) => _commit(() => _set(h: v)),
            LinearGradient(colors: hueColors)),
        _row('S', '${(_s * 100).round()}%', 100, _s, (v) => _set(s: v), (v) => _commit(() => _set(s: v / 100)),
            LinearGradient(colors: [InkColor.hsb(_h, 0, _b).toColor(), InkColor.hsb(_h, 1, _b).toColor()])),
        _row('B', '${(_b * 100).round()}%', 100, _b, (v) => _set(b: v), (v) => _commit(() => _set(b: v / 100)),
            LinearGradient(colors: [Colors.black, InkColor.hsb(_h, _s, 1).toColor()])),
        _row('A', '${(_a * 100).round()}%', 100, _a, (v) => _set(a: v), (v) => _commit(() => _set(a: v / 100)),
            LinearGradient(colors: [InkColor.hsb(_h, _s, _b, 0).toColor(), InkColor.hsb(_h, _s, _b).toColor()]),
            checker: true),
        const SizedBox(height: 8),
        Row(children: [
          const Expanded(child: Text('Hex #', style: TextStyle(fontSize: 16))),
          _NumberBox(
            text: _current.hexValue.substring(1).toUpperCase(),
            width: 104,
            onSubmitted: (t) {
              final hex = t.trim().replaceFirst('#', '');
              if (!RegExp(r'^([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(hex)) return;
              final c = InkColor.fromHex(hex);
              _commit(() {
                setState(() => _sync(c.withAlpha(_a), keepHue: true));
                widget.onChanged(_current);
              });
            },
          ),
        ]),
      ]),
    );
  }

  /// One labelled gradient slider. [max] is the numeric field's range.
  Widget _row(String label, String readout, double max, double value, ValueChanged<double> onDrag,
      ValueChanged<double> onTyped, Gradient track,
      {bool checker = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
          _NumberBox(
            text: readout,
            onSubmitted: (t) {
              final v = double.tryParse(t.replaceAll(RegExp(r'[^0-9.]'), ''));
              if (v != null) onTyped(v.clamp(0, max));
            },
          ),
        ]),
        const SizedBox(height: 6),
        GradientSlider(
          value: value,
          track: track,
          checker: checker,
          onChangeStart: widget.onChangeStart,
          onChanged: onDrag,
          onChangeEnd: widget.onChangeEnd,
        ),
      ]),
    );
  }
}

/// A small outlined, editable readout (e.g. "25°", "100%").
class _NumberBox extends StatefulWidget {
  final String text;
  final double width;
  final ValueChanged<String> onSubmitted;

  const _NumberBox({required this.text, required this.onSubmitted, this.width = 74});

  @override
  State<_NumberBox> createState() => _NumberBoxState();
}

class _NumberBoxState extends State<_NumberBox> {
  late final _controller = TextEditingController(text: widget.text);
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_NumberBox old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _controller.text != widget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.width,
      height: 30,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        textAlign: TextAlign.center,
        style: TextStyle(color: primary, fontSize: 15),
        inputFormatters: [LengthLimitingTextInputFormatter(9)],
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: primary), borderRadius: BorderRadius.circular(6)),
          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: primary, width: 2), borderRadius: BorderRadius.circular(6)),
        ),
        onSubmitted: widget.onSubmitted,
        onTapOutside: (_) {
          if (_focus.hasFocus) {
            widget.onSubmitted(_controller.text);
            _focus.unfocus();
          }
        },
      ),
    );
  }
}

/// A rounded gradient track with a round thumb.
class GradientSlider extends StatelessWidget {
  final double value;
  final Gradient track;
  final bool checker;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  const GradientSlider({
    super.key,
    required this.value,
    required this.track,
    required this.onChanged,
    this.checker = false,
    this.onChangeStart,
    this.onChangeEnd,
  });

  static const _height = 26.0, _thumb = 30.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      double toValue(double x) => ((x - _thumb / 2) / (w - _thumb)).clamp(0.0, 1.0);
      return Semantics(
        slider: true,
        value: '${(value * 100).round()}%',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            onChangeStart?.call();
            onChanged(toValue(d.localPosition.dx));
          },
          onHorizontalDragUpdate: (d) => onChanged(toValue(d.localPosition.dx)),
          onHorizontalDragEnd: (_) => onChangeEnd?.call(),
          onTapDown: (d) {
            onChangeStart?.call();
            onChanged(toValue(d.localPosition.dx));
            onChangeEnd?.call();
          },
          child: SizedBox(
            height: _thumb,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(
                left: _thumb / 2 - _height / 2,
                right: _thumb / 2 - _height / 2,
                top: (_thumb - _height) / 2,
                height: _height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_height / 2),
                  child: CustomPaint(painter: _TrackPainter(track, checker)),
                ),
              ),
              Positioned(
                left: value.clamp(0.0, 1.0) * (w - _thumb),
                top: 0,
                child: Container(
                  width: _thumb,
                  height: _thumb,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1))],
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

class _TrackPainter extends CustomPainter {
  final Gradient gradient;
  final bool checker;

  _TrackPainter(this.gradient, this.checker);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    if (checker) paintChecker(canvas, r);
    canvas.drawRect(r, Paint()..shader = gradient.createShader(r));
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.gradient != gradient;
}

/// The light checkerboard used behind transparent colors.
void paintChecker(Canvas canvas, Rect r, {double cell = 6}) {
  canvas.drawRect(r, Paint()..color = Colors.white);
  final gray = Paint()..color = const Color(0xFFD9D9D9);
  for (var y = 0; y * cell < r.height; y++) {
    for (var x = y.isEven ? 0 : 1; x * cell < r.width; x += 2) {
      canvas.drawRect(Rect.fromLTWH(r.left + x * cell, r.top + y * cell, cell, cell), gray);
    }
  }
}
