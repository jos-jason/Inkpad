import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/units.dart';

/// A box for a length (or another number), shown in the drawing's unit.
/// Accepts other units and sums ("1 3/8"", "25.4mm", "300-2*12"); applies
/// on Enter or when focus leaves; Escape puts the value back. Named
/// measurements can be used by name; with [onFormula], the sum is kept
/// (shown as [formula], marked ƒ) so the value follows them.
class LengthField extends StatefulWidget {
  /// In points (or plain numbers when [parse]/[format] are given).
  final double value;
  final LengthFormat lengths;
  final ValueChanged<double> onChanged;
  final String? label;
  final double width;
  final bool enabled;

  /// For non-length numbers (angles, counts, percentages).
  final String Function(double)? format;
  final double? Function(String)? parse;

  /// The sum this value was typed as, shown while typing.
  final String? formula;

  /// Called instead of [onChanged] when the text uses named measurements.
  final void Function(String text, double value)? onFormula;

  const LengthField({
    super.key,
    required this.value,
    required this.lengths,
    required this.onChanged,
    this.label,
    this.width = 96,
    this.enabled = true,
    this.format,
    this.parse,
    this.formula,
    this.onFormula,
  });

  @override
  State<LengthField> createState() => _LengthFieldState();
}

class _LengthFieldState extends State<LengthField> {
  late final _text = TextEditingController(text: _shown);
  final _focus = FocusNode();
  bool _invalid = false;

  String get _shown => widget.format?.call(widget.value) ?? widget.lengths.format(widget.value);

  /// What's there to edit: the formula, if there is one.
  String get _editText => widget.formula ?? _shown;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        _apply();
      } else {
        if (_text.text == _shown) _text.text = _editText;
        _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
      }
    });
  }

  @override
  void didUpdateWidget(LengthField old) {
    super.didUpdateWidget(old);
    // Follow outside changes, but not while being typed into.
    if (!_focus.hasFocus && _text.text != _shown) _text.text = _shown;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _apply() {
    if (_text.text == _shown || _text.text == _editText) {
      setState(() => _invalid = false);
      if (!_focus.hasFocus) _text.text = _shown;
      return;
    }
    final v = widget.parse != null ? widget.parse!(_text.text) : widget.lengths.parse(_text.text);
    if (v == null) {
      setState(() => _invalid = true);
      return;
    }
    setState(() => _invalid = false);
    if (widget.onFormula != null && LengthFormat.namesIn(_text.text).isNotEmpty) {
      widget.onFormula!(_text.text.trim(), v);
    } else if ((v - widget.value).abs() > 1e-9) {
      widget.onChanged(v);
    }
    // Show it the standard way (e.g. "1in" becomes "25.4 mm").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _text.text = _shown;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            _text.text = _shown;
            setState(() => _invalid = false);
            _focus.unfocus();
          },
        },
        child: TextField(
          controller: _text,
          focusNode: _focus,
          enabled: widget.enabled,
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
          onSubmitted: (_) => _apply(),
          decoration: InputDecoration(
            isDense: true,
            labelText: widget.label,
            prefixText: widget.formula != null ? 'ƒ ' : null,
            prefixStyle: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, fontStyle: FontStyle.italic),
            errorText: _invalid ? (LengthFormat.namesIn(_text.text).isNotEmpty ? 'Unknown name' : 'Not a size') : null,
            errorStyle: const TextStyle(height: 0.8, fontSize: 10),
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          ),
        ),
      ),
    );
  }
}
