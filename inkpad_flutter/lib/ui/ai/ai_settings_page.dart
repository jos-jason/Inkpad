import 'package:flutter/material.dart';

import '../../ai/ai_client.dart';
import '../../ai/ai_settings.dart';
import '../../library/library_controller.dart';

/// The AI services you've set up, and which one is in use. Each uses your
/// own key (or a local Ollama, which needs none).
class AiSettingsPage extends StatefulWidget {
  final AiSettings settings;

  const AiSettingsPage({super.key, required this.settings});

  static Future<void> open(BuildContext context, [AiSettings? settings]) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AiSettingsPage(settings: settings ?? AiSettings.instance)),
      );

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  AiSettings get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    settings.load();
  }

  Future<void> _edit([AiSetup? setup]) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AiSetupPage(settings: settings, setup: setup)),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final theme = Theme.of(context);
        final active = settings.active;
        return Scaffold(
          appBar: AppBar(title: const Text('AI')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('Add AI service'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  'Inkpad uses your own AI account: Claude (Anthropic), any OpenAI-compatible service, or Ollama '
                  'running on your computer. Requests go straight from this device to the service; only what you '
                  'ask about is sent, and only when you ask.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (settings.keyStoreProblem != null)
                ListTile(
                  leading: Icon(Icons.warning_amber, color: theme.colorScheme.error),
                  title: Text(settings.keyStoreProblem!),
                ),
              if (!settings.loaded)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (settings.setups.isEmpty)
                const ListTile(
                  leading: Icon(Icons.auto_awesome_outlined),
                  title: Text('No AI service yet'),
                  subtitle: Text('Tap "Add AI service" to connect one.'),
                ),
              for (final s in settings.setups)
                ListTile(
                  leading: Icon(
                    identical(s, active) ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: identical(s, active) ? theme.colorScheme.primary : null,
                  ),
                  title: Text(s.name),
                  subtitle: Text('${s.kind.label} · quick: ${_or(s.quickModel)} · drawing: ${_or(s.strongModel)}'),
                  trailing: IconButton(tooltip: 'Edit ${s.name}', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(s)),
                  onTap: () => settings.use(s),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _or(String model) => model.isEmpty ? '(not set)' : model;
}

/// Adding or changing one AI service.
class AiSetupPage extends StatefulWidget {
  final AiSettings settings;
  final AiSetup? setup;

  const AiSetupPage({super.key, required this.settings, this.setup});

  @override
  State<AiSetupPage> createState() => _AiSetupPageState();
}

class _AiSetupPageState extends State<AiSetupPage> {
  late AiProviderKind _kind = widget.setup?.kind ?? AiProviderKind.anthropic;
  late final _name = TextEditingController(text: widget.setup?.name ?? _kind.label);
  late final _url = TextEditingController(text: widget.setup?.baseUrl ?? _kind.defaultBaseUrl);
  late final _key = TextEditingController(text: widget.setup == null ? '' : widget.settings.keyFor(widget.setup!) ?? '');
  late final _quick = TextEditingController(text: widget.setup?.quickModel ?? AiSetup.defaultModels(_kind).$1);
  late final _strong = TextEditingController(text: widget.setup?.strongModel ?? AiSetup.defaultModels(_kind).$2);
  late bool? _vision = widget.setup?.vision;
  late Set<String> _visionModels = {...?widget.setup?.visionModels};
  late final String _originalKey = _key.text;

  bool _showKey = false;
  List<AiModelInfo> _models = [];
  bool _busy = false;
  String? _status;
  bool _statusOk = false;

  @override
  void dispose() {
    for (final c in [_name, _url, _key, _quick, _strong]) {
      c.dispose();
    }
    super.dispose();
  }

  void _setKind(AiProviderKind k) {
    setState(() {
      // Follow the provider's defaults unless they were changed by hand.
      if (_url.text == _kind.defaultBaseUrl || _url.text.isEmpty) _url.text = k.defaultBaseUrl;
      if (_name.text == _kind.label || _name.text.isEmpty) _name.text = k.label;
      final (q, s) = AiSetup.defaultModels(k);
      _quick.text = q;
      _strong.text = s;
      _kind = k;
      _models = [];
      _status = null;
    });
  }

  AiClient _client() => AiClient.of(_kind, baseUrl: _url.text.trim(), apiKey: _key.text.trim(), client: widget.settings.httpClient?.call());

  Future<void> _loadModels() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final client = _client();
    try {
      final models = await client.listModels();
      setState(() {
        _models = models;
        _visionModels = {for (final m in models) if (m.vision == true) m.id};
        _status = models.isEmpty ? 'Connected, but no models were listed.' : 'Found ${models.length} models.';
        _statusOk = models.isNotEmpty;
      });
    } on AiException catch (e) {
      setState(() {
        _status = e.message;
        _statusOk = false;
      });
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if (_quick.text.trim().isEmpty) {
      setState(() {
        _status = 'Choose a quick model first (Load models lists them).';
        _statusOk = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    final client = _client();
    try {
      final r = await client.send(AiRequest(
        model: _quick.text.trim(),
        system: 'You are a connection test.',
        messages: const [AiMessage.user('Reply with just the word OK.')],
        maxTokens: 20,
      ));
      setState(() {
        _status = 'Connected: ${_quick.text.trim()} said "${r.text.trim()}".';
        _statusOk = true;
      });
    } on AiException catch (e) {
      setState(() {
        _status = e.message;
        _statusOk = false;
      });
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final s = widget.setup ?? AiSetup(id: LibraryController.newId(), name: '', kind: _kind, baseUrl: '');
    s
      ..name = _name.text.trim().isEmpty ? _kind.label : _name.text.trim()
      ..kind = _kind
      ..baseUrl = _url.text.trim()
      ..quickModel = _quick.text.trim()
      ..strongModel = _strong.text.trim()
      ..vision = _vision
      ..visionModels = _visionModels;
    final key = _key.text.trim();
    await widget.settings.save(s, key: key, keyChanged: widget.setup == null || key != _originalKey);
    if (widget.setup == null) await widget.settings.use(s);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final s = widget.setup;
    if (s == null) return;
    await widget.settings.remove(s);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _modelField(String label, String help, TextEditingController c) {
    if (_models.isEmpty) {
      return TextField(
        controller: c,
        decoration: InputDecoration(labelText: label, helperText: help, border: const OutlineInputBorder()),
      );
    }
    return LayoutBuilder(
      builder: (context, box) => DropdownMenu<String>(
        controller: c,
        width: box.maxWidth,
        label: Text(label),
        helperText: help,
        enableFilter: true,
        requestFocusOnTap: true,
        menuHeight: 320,
        dropdownMenuEntries: [
          for (final m in _models)
            DropdownMenuEntry(value: m.id, label: m.id, trailingIcon: m.vision == true ? const Icon(Icons.visibility_outlined, size: 16) : null),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyHint = switch (_kind) {
      AiProviderKind.anthropic => 'From console.anthropic.com',
      AiProviderKind.openAi => 'If the service needs one',
      AiProviderKind.ollama => 'Not needed for a local Ollama',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.setup == null ? 'Add AI service' : 'Edit AI service'),
        actions: [
          if (widget.setup != null) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<AiProviderKind>(
            segments: const [
              ButtonSegment(value: AiProviderKind.anthropic, label: Text('Claude')),
              ButtonSegment(value: AiProviderKind.openAi, label: Text('OpenAI-compatible')),
              ButtonSegment(value: AiProviderKind.ollama, label: Text('Ollama')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => _setKind(s.single),
          ),
          const SizedBox(height: 16),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Address',
              helperText: _kind == AiProviderKind.ollama
                  ? 'On another computer? Use its address, e.g. http://192.168.1.20:11434'
                  : _kind == AiProviderKind.openAi
                      ? 'e.g. https://api.openai.com/v1, https://openrouter.ai/api/v1, http://localhost:1234/v1'
                      : null,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API key',
              helperText: '$keyHint. Kept in this device\'s secure storage.',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _showKey ? 'Hide key' : 'Show key',
                icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _loadModels,
              icon: const Icon(Icons.list),
              label: const Text('Load models'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Test connection'),
            ),
            if (_busy) const Padding(padding: EdgeInsets.only(left: 12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          ]),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status!, style: TextStyle(color: _statusOk ? theme.colorScheme.primary : theme.colorScheme.error)),
            ),
          const SizedBox(height: 20),
          _modelField('Quick model', 'For quick edits: fast and cheap (e.g. Claude Haiku, a small local model)', _quick),
          const SizedBox(height: 16),
          _modelField('Drawing model', 'For drawing from a description: your strongest (e.g. Claude Opus)', _strong),
          const SizedBox(height: 20),
          Text('Can the models see a picture of the drawing?', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<bool?>(
            segments: const [
              ButtonSegment(value: null, label: Text('Automatic')),
              ButtonSegment(value: true, label: Text('Yes')),
              ButtonSegment(value: false, label: Text('No')),
            ],
            selected: {_vision},
            onSelectionChanged: (s) => setState(() => _vision = s.single),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'A picture helps with layout and style, but costs more and not every model can take one.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
