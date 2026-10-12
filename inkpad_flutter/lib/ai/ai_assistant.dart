import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../controller/drawing_controller.dart';
import '../export/raster_export.dart';
import 'ai_client.dart';
import 'ai_edits.dart';
import 'ai_settings.dart';

/// What the assistant is asked to do: change the drawing (with the quick
/// model) or draw something new (with the strong model).
enum AiMode { edit, draw }

/// The outcome of one request, already applied to the drawing (as one undo
/// step) so it can be previewed.
class AiOutcome {
  final String summary;
  final List<String> problems;
  final bool changed;

  /// What was asked (without the picture) and the model's answer, kept so a
  /// follow-up ("a bit darker") has context.
  final AiMessage asked;
  final AiMessage reply;

  const AiOutcome(this.summary, this.problems, this.changed, this.asked, this.reply);
}

const _editSystem = '''
You are the editing assistant inside Inkpad, a vector drawing app. The user asks for a change; you make it by calling the edit_drawing tool once with a list of operations.

The drawing is given as JSON: the page size, the ids of the selected elements, and each layer's elements (id, type, box [x, y, width, height], fill, stroke, text, font, opacity, shadow; groups list their children). Coordinates are points, with the origin at the top left of the page, x to the right and y down. Angles are in degrees, clockwise.

Rules:
- Change only what the user asks for; leave everything else alone.
- When the request doesn't say which elements, use the selected ones; if nothing is selected, the whole drawing.
- Use only ids that appear in the JSON. Colors are #rrggbb or CSS color names; "none" removes a fill, stroke or shadow.
- Arrowheads (start_arrow, end_arrow): {arrows}, or "none".
- To add new shapes, use add_svg with a small complete SVG and the box (x, y, width, height) to place it in.
- summary: one short, friendly sentence saying what you changed. If the request can't be done, return no operations and explain why in summary.
If you cannot call tools, reply with only the JSON object {"summary": ..., "operations": [...]}.''';

const _drawSystem = '''
You create vector artwork for Inkpad, a vector drawing app. Reply with one complete SVG document inside a ```svg code block, then at most one short sentence.

- Choose a viewBox that suits the artwork; it will be scaled to fit the area given.
- Use paths, basic shapes and groups, with solid fills, linear or radial gradients and strokes.
- No <text> unless words are asked for. No images, filters, masks, scripts, external references, CSS or animation.
- Keep it clean and editable: meaningful <g> groups, no more than about 150 shapes, no hidden or empty elements.''';

class AiAssistant {
  final DrawingController controller;
  final AiSettings settings;

  AiClient? _client;

  AiAssistant(this.controller, this.settings);

  /// Stops the request in progress.
  void cancel() {
    _client?.close();
    _client = null;
  }

  /// Sends [prompt] (with any earlier messages of this conversation) and
  /// applies the answer as one undo step. Throws [AiException] when the
  /// service or the answer fails.
  Future<AiOutcome> run(AiMode mode, String prompt, {List<AiMessage> history = const [], bool withPicture = true}) async {
    final setup = settings.active;
    if (setup == null || !setup.isComplete) throw const AiException('Set up an AI service first (Settings → AI).');
    final model = mode == AiMode.edit ? setup.quickModel : setup.strongModel;
    final picture = withPicture && setup.canSeeImages(model) ? await _picture() : null;
    final client = _client = settings.clientFor(setup);
    try {
      return mode == AiMode.edit
          ? await _edit(client, model, prompt, history, picture)
          : await _draw(client, model, prompt, history, picture);
    } finally {
      if (identical(_client, client)) _client = null;
    }
  }

  /// The page as a small PNG, for models that can see.
  Future<Uint8List> _picture() async {
    final d = controller.drawing;
    return drawingToPng(d, scale: math.min(1.0, 1024 / math.max(d.width, d.height)));
  }

  Future<AiOutcome> _edit(AiClient client, String model, String prompt, List<AiMessage> history, Uint8List? picture) async {
    final brief = DrawingBrief.of(controller);
    final message = AiMessage.user(
      'Request: $prompt\n\nDrawing:\n```json\n${brief.json}\n```',
      image: picture,
    );
    final system = _editSystem.replaceFirst('{arrows}', arrowNames);
    final messages = [...history, message];
    AiResponse response;
    try {
      response = await client.send(AiRequest(model: model, system: system, messages: messages, tool: editTool, maxTokens: 4096));
    } on AiException catch (e) {
      // Some models can't use tools: ask for the JSON in text instead.
      if (!e.message.toLowerCase().contains('tool')) rethrow;
      response = await client.send(AiRequest(model: model, system: system, messages: messages, maxTokens: 4096));
    }
    final answer = response.toolArguments ?? jsonObjectIn(response.text);
    if (answer == null) {
      final said = response.text.trim();
      throw AiException(said.isEmpty ? 'The AI didn\'t answer with any changes.' : 'The AI didn\'t make changes: $said');
    }
    final result = applyEdits(controller, brief, answer);
    return AiOutcome(
      result.summary.isEmpty ? 'Done.' : result.summary,
      result.problems,
      result.applied > 0,
      AiMessage.user(message.text),
      AiMessage.assistant(jsonEncode(answer)),
    );
  }

  Future<AiOutcome> _draw(AiClient client, String model, String prompt, List<AiMessage> history, Uint8List? picture) async {
    final c = controller;
    final d = c.drawing;
    // Where it goes: inside the selection, or the middle of the page.
    final Rect area;
    final sel = c.selectionBounds;
    if (sel != null && sel.width > 10 && sel.height > 10) {
      area = sel;
    } else {
      final side = math.min(d.width, d.height) * 0.6;
      area = Rect.fromCenter(center: Offset(d.width / 2, d.height / 2), width: side, height: side);
    }
    final palette = DrawingBrief.palette(d);
    final message = AiMessage.user(
      'Draw: $prompt\n\n'
      'It will be placed in an area ${area.width.round()} × ${area.height.round()} points'
      '${palette.isEmpty ? '' : '; colors already in the drawing: ${palette.join(', ')} (use them if they suit)'}.'
      '${picture != null ? ' The picture shows the drawing so far.' : ''}',
      image: picture,
    );
    final response = await client.send(AiRequest(model: model, system: _drawSystem, messages: [...history, message], maxTokens: 16000));
    final svg = svgIn(response.text);
    if (svg == null) {
      final said = response.text.trim();
      throw AiException(said.isEmpty ? 'The AI didn\'t send any artwork.' : 'The AI didn\'t send artwork: ${said.length > 200 ? '${said.substring(0, 200)}…' : said}');
    }
    final notes = <String>[];
    c.batch(() => notes.addAll(placeSvg(c, svg, x: area.left, y: area.top, width: area.width, height: area.height)));
    final words = response.text.replaceAll(RegExp(r'```[\s\S]*?```'), '').replaceAll(RegExp(r'<svg[\s\S]*</svg>'), '').trim();
    return AiOutcome(words.isEmpty ? 'Added the artwork.' : words, notes, true, AiMessage.user(message.text), AiMessage.assistant(response.text));
  }
}

/// The SVG document in a model's answer (fenced or bare).
String? svgIn(String text) {
  final fence = RegExp(r'```(?:svg|xml)?\s*(<svg[\s\S]*?</svg>)\s*```').firstMatch(text);
  if (fence != null) return fence.group(1);
  final bare = RegExp(r'<svg[\s\S]*</svg>').firstMatch(text);
  return bare?.group(0);
}
