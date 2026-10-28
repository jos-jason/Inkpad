import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/ai_assistant.dart';
import '../../ai/ai_client.dart';
import '../../ai/ai_settings.dart';
import '../../controller/drawing_controller.dart';
import '../chrome/chrome.dart';
import 'ai_settings_page.dart';

/// The ✨ panel: ask the AI to change the drawing (quick model) or draw
/// something new (drawing model). Results show on the canvas straight away;
/// Keep them, Undo them, or say what to change.
class AiPanel extends StatefulWidget {
  final DrawingController controller;
  final AiSettings settings;

  AiPanel({super.key, required this.controller, AiSettings? settings}) : settings = settings ?? AiSettings.instance;

  @override
  State<AiPanel> createState() => _AiPanelState();
}

enum _Stage { asking, working, preview }

class _AiPanelState extends State<AiPanel> {
  late final _assistant = AiAssistant(widget.controller, widget.settings);
  final _prompt = TextEditingController();
  final _focus = FocusNode();

  static AiMode _mode = AiMode.edit;
  static bool _withPicture = true;

  _Stage _stage = _Stage.asking;
  String? _error;
  AiOutcome? _outcome;

  /// The conversation so far (for follow-ups), and the selection to put
  /// back when a preview is undone.
  final List<AiMessage> _history = [];
  List<(int, int)> _selectionBefore = [];

  DrawingController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    widget.settings.load();
    // An empty selection with nothing to edit suggests drawing.
    if (c.drawing.allElements.isEmpty) _mode = AiMode.draw;
  }

  @override
  void dispose() {
    // Closing while working stops the request; a preview is kept.
    if (_stage == _Stage.working) _assistant.cancel();
    _prompt.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _stage == _Stage.working) return;
    // A follow-up replaces the preview: undo it and ask again with context.
    if (_stage == _Stage.preview) _undoPreview(keepConversation: true);
    _selectionBefore = c.selectionPositions;
    setState(() {
      _stage = _Stage.working;
      _error = null;
    });
    try {
      final outcome = await _assistant.run(_mode, text, history: List.of(_history), withPicture: _withPicture);
      if (!mounted) return;
      _history.addAll([outcome.asked, outcome.reply]);
      _prompt.clear();
      setState(() {
        _outcome = outcome;
        _stage = outcome.changed ? _Stage.preview : _Stage.asking;
        if (!outcome.changed) _error = outcome.summary;
      });
    } on AiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _stage = _Stage.asking;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Something went wrong: $e';
          _stage = _Stage.asking;
        });
      }
    }
  }

  void _stop() {
    _assistant.cancel();
    setState(() {
      _stage = _Stage.asking;
      _error = 'Stopped.';
    });
  }

  void _keep() {
    setState(() {
      _stage = _Stage.asking;
      _outcome = null;
      _history.clear();
    });
  }

  void _undoPreview({bool keepConversation = false}) {
    c.discardLastStep();
    c.selectPositions(_selectionBefore);
    setState(() {
      _stage = _Stage.asking;
      _outcome = null;
      if (!keepConversation) _history.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.settings, c, _prompt]),
      builder: (context, _) {
        final settings = widget.settings;
        final setup = settings.active;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverHeader(
              'AI',
              trailing: IconButton(
                tooltip: 'AI settings',
                icon: const Icon(Icons.tune),
                onPressed: () => AiSettingsPage.open(context, settings),
              ),
            ),
            if (!settings.loaded)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (setup == null || !setup.isComplete)
              _setUp(context, setup)
            else
              ..._body(context, setup),
          ],
        );
      },
    );
  }

  Widget _setUp(BuildContext context, AiSetup? setup) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            setup == null
                ? 'Connect an AI service to edit by describing changes and draw from a description. '
                    'Use your own Claude key, any OpenAI-compatible service, or Ollama on your computer.'
                : 'Choose a quick model and a drawing model for "${setup.name}".',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => AiSettingsPage.open(context, widget.settings),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Set up AI…'),
          ),
        ]),
      );

  List<Widget> _body(BuildContext context, AiSetup setup) {
    final theme = Theme.of(context);
    final model = _mode == AiMode.edit ? setup.quickModel : setup.strongModel;
    final selected = c.selection.length;
    final scope = switch (_mode) {
      AiMode.edit => selected == 0
          ? 'Changes the whole drawing (select shapes to change just those).'
          : 'Changes the $selected selected ${selected == 1 ? 'item' : 'items'}.',
      AiMode.draw => selected == 0 ? 'Draws in the middle of the page (or select an area to draw in).' : 'Draws inside the selected area.',
    };
    final suggestions = _mode == AiMode.edit
        ? const ['Make the colors warmer', 'Align these and space them evenly', 'Add a soft drop shadow', 'Make the outlines thicker']
        : const ['A simple line-art cat', 'A badge with a ribbon', 'A house icon', 'A wavy sunset landscape'];
    final working = _stage == _Stage.working;
    final outcome = _outcome;

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SegmentedButton<AiMode>(
          segments: const [
            ButtonSegment(value: AiMode.edit, icon: Icon(Icons.edit_outlined), label: Text('Edit')),
            ButtonSegment(value: AiMode.draw, icon: Icon(Icons.brush_outlined), label: Text('Draw')),
          ],
          selected: {_mode},
          onSelectionChanged: working ? null : (s) => setState(() => _mode = s.single),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('$scope Uses ${setup.name}: $model.', style: theme.textTheme.bodySmall),
      ),
      if (outcome != null && _stage == _Stage.preview)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(outcome.summary, style: theme.textTheme.bodyMedium),
            if (outcome.problems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  outcome.problems.take(4).join('\n') + (outcome.problems.length > 4 ? '\n…' : ''),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton(onPressed: _keep, child: const Text('Keep')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _undoPreview, child: const Text('Undo')),
              const Spacer(),
              Flexible(child: Text('or say what to change below', style: theme.textTheme.bodySmall, textAlign: TextAlign.end)),
            ]),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
            const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
          },
          child: TextField(
            controller: _prompt,
            focusNode: _focus,
            autofocus: true,
            enabled: !working,
            // Tapping elsewhere puts the keyboard away (phones have no key for it).
            onTapOutside: (_) => _focus.unfocus(),
            minLines: 2,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: _stage == _Stage.preview
                  ? 'Not quite? e.g. "a bit darker", "only the circles"'
                  : _mode == AiMode.edit
                      ? 'Describe a change, e.g. "make the title red and bigger"'
                      : 'Describe what to draw, e.g. "a friendly cartoon owl"',
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ),
      if (_stage == _Stage.asking && _prompt.text.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final s in suggestions)
              ActionChip(
                label: Text(s, style: theme.textTheme.bodySmall),
                onPressed: () => setState(() => _prompt.text = s),
              ),
          ]),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
        child: Row(children: [
          if (setup.canSeeImages(model))
            Expanded(
              child: CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('Include a picture'),
                value: _withPicture,
                onChanged: working ? null : (v) => setState(() => _withPicture = v ?? true),
              ),
            )
          else
            const Spacer(),
          if (working) ...[
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            TextButton(onPressed: _stop, child: const Text('Stop')),
          ] else
            FilledButton.icon(
              onPressed: _send,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(_stage == _Stage.preview ? 'Redo' : (_mode == AiMode.edit ? 'Change' : 'Draw')),
            ),
        ]),
      ),
    ];
  }
}
