import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/drawing_controller.dart';
import '../model/element.dart';
import 'chrome/chrome.dart';
import 'drawing_canvas.dart';

/// The field you type into while editing text. It floats just below the
/// text, which updates on the canvas as you type (like Inkpad's text
/// editing popover, WDTextController).
class TextEditorOverlay extends StatefulWidget {
  final DrawingController controller;
  final CanvasView view;

  /// Where the canvas's top-left corner sits in the overlay's coordinates.
  final Offset origin;

  const TextEditorOverlay({super.key, required this.controller, required this.view, required this.origin});

  @override
  State<TextEditorOverlay> createState() => _TextEditorOverlayState();
}

class _TextEditorOverlayState extends State<TextEditorOverlay> {
  static const _width = 320.0;

  late final InkStylable target = widget.controller.editingText!;
  late final _text = TextEditingController(text: _current);
  final _focus = FocusNode();

  bool get _singleLine => target is InkTextPath;
  String get _current => switch (target) { InkText t => t.text, InkTextPath t => t.text, _ => '' };

  @override
  void initState() {
    super.initState();
    // New text starts as "Text", selected so typing replaces it.
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    _text.addListener(() {
      if (_text.text != _current) widget.controller.updateEditingText(_text.text);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _done() => widget.controller.endEditing();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListenableBuilder(
        listenable: widget.view,
        builder: (context, _) {
          final b = target.bounds;
          final below = widget.view.toScreen(b.bottomCenter) + widget.origin;
          final above = widget.view.toScreen(b.topCenter) + widget.origin;
          const height = 132.0;
          // Below the text if it fits, else above it; always on screen.
          final y = below.dy + 12 + height < constraints.maxHeight - 80 ? below.dy + 12 : above.dy - 12 - height;
          final x = (below.dx - _width / 2).clamp(8.0, (constraints.maxWidth - _width - 8).clamp(8.0, double.infinity));
          return Stack(children: [
            Positioned(
              left: x,
              top: y.clamp(70.0, (constraints.maxHeight - height - 80).clamp(70.0, double.infinity)),
              width: _width,
              child: Pill(
                radius: 14,
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.escape): _done,
                        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _done,
                        const SingleActivator(LogicalKeyboardKey.enter, control: true): _done,
                      },
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: _singleLine ? 1 : 4,
                        keyboardType: _singleLine ? TextInputType.text : TextInputType.multiline,
                        textInputAction: _singleLine ? TextInputAction.done : TextInputAction.newline,
                        onSubmitted: _singleLine ? (_) => _done() : null,
                        decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: 'Type text'),
                      ),
                    ),
                  ),
                  TextButton(onPressed: _done, child: const Text('Done')),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
