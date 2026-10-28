import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inkpad/ai/ai_assistant.dart';
import 'package:inkpad/ai/ai_client.dart';
import 'package:inkpad/ai/ai_edits.dart';
import 'package:inkpad/ai/ai_settings.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/bezier_node.dart';
import 'package:inkpad/model/element.dart';
import 'package:inkpad/model/style.dart';
import 'package:inkpad/ui/ai/ai_panel.dart';

import 'helpers/test_fonts.dart';

const red = InkColor(1, 0, 0), blue = InkColor(0, 0, 1);

/// A fake service: records requests, answers with [reply].
class Fake {
  final List<http.Request> requests = [];
  http.Response Function(http.Request) reply;

  Fake(this.reply);

  http.Client client() => MockClient((r) async {
        requests.add(r);
        return reply(r);
      });

  Map<String, dynamic> get lastBody => jsonDecode(requests.last.body) as Map<String, dynamic>;
}

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// What Claude sends back when it calls the edit tool.
http.Response claudeEdits(String summary, List<Map<String, dynamic>> ops) => json({
      'content': [
        {
          'type': 'tool_use',
          'name': 'edit_drawing',
          'input': {'summary': summary, 'operations': ops},
        },
      ],
    });

DrawingController sample() {
  final c = DrawingController();
  c.addElement(InkPath.rect(const Rect.fromLTWH(10, 10, 50, 50))..fill = red);
  c.addElement(InkPath.oval(const Rect.fromLTWH(100, 10, 50, 50))..fill = blue);
  c.addElement(InkPath(nodes: [const BezierNode.anchor(Offset(0, 200)), const BezierNode.anchor(Offset(100, 200))])..stroke = const StrokeStyle());
  return c;
}

Future<AiSettings> settingsWith(Fake fake, AiProviderKind kind, {String quick = 'small', String strong = 'big', bool? vision = false}) async {
  final s = AiSettings(MemoryAiSettingsStore(), httpClient: fake.client);
  await s.load();
  await s.save(
    AiSetup(id: 'a', name: 'Test AI', kind: kind, baseUrl: kind.defaultBaseUrl, quickModel: quick, strongModel: strong, vision: vision),
    key: 'sk-test',
    keyChanged: true,
  );
  return s;
}

void main() {
  setUpAll(initTestFonts);

  group('clients', () {
    const tool = AiTool('t', 'a tool', {'type': 'object', 'properties': {}});
    const request = AiRequest(model: 'm', system: 'sys', messages: [AiMessage.user('hi')], tool: tool);

    test('Claude: key header, tool forced, tool input read', () async {
      final fake = Fake((_) => json({
            'content': [
              {'type': 'text', 'text': 'ok '},
              {'type': 'tool_use', 'name': 't', 'input': {'a': 1}},
            ],
          }));
      final r = await AiClient.of(AiProviderKind.anthropic, baseUrl: 'https://api.anthropic.com', apiKey: 'k', client: fake.client()).send(request);
      expect(fake.requests.single.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(fake.requests.single.headers['x-api-key'], 'k');
      expect(fake.lastBody['system'], 'sys');
      expect(fake.lastBody['tool_choice'], {'type': 'tool', 'name': 't'});
      expect(r.text, 'ok ');
      expect(r.toolArguments, {'a': 1});
    });

    test('OpenAI-compatible: bearer key, function tool, string arguments; images as data URLs', () async {
      final fake = Fake((_) => json({
            'choices': [
              {
                'message': {
                  'content': null,
                  'tool_calls': [
                    {'function': {'name': 't', 'arguments': '{"b": 2}'}},
                  ],
                },
              },
            ],
          }));
      final client = AiClient.of(AiProviderKind.openAi, baseUrl: 'https://openrouter.ai/api/v1/', apiKey: 'k', client: fake.client());
      final r = await client.send(const AiRequest(
        model: 'm',
        system: 'sys',
        messages: [AiMessage.user('look', image: null)],
        tool: tool,
      ));
      expect(fake.requests.single.url.toString(), 'https://openrouter.ai/api/v1/chat/completions');
      expect(fake.requests.single.headers['authorization'], 'Bearer k');
      expect(fake.lastBody['messages'][0], {'role': 'system', 'content': 'sys'});
      expect(r.toolArguments, {'b': 2});
    });

    test('Ollama: no key, local chat API, JSON in text when it doesn\'t call the tool', () async {
      final fake = Fake((_) => json({
            'message': {'content': 'Sure!\n```json\n{"summary": "x", "operations": []}\n```'},
          }));
      final client = AiClient.of(AiProviderKind.ollama, baseUrl: 'http://localhost:11434', client: fake.client());
      final r = await client.send(request);
      expect(fake.requests.single.url.toString(), 'http://localhost:11434/api/chat');
      expect(fake.requests.single.headers.containsKey('authorization'), isFalse);
      expect(fake.lastBody['stream'], false);
      expect(r.toolArguments, isNull);
      expect(jsonObjectIn(r.text), {'summary': 'x', 'operations': []});
    });

    test('model lists, including what Ollama models can do', () async {
      final fake = Fake((r) => switch (r.url.path) {
            '/api/tags' => json({
                'models': [
                  {'name': 'qwen3:8b'},
                  {'name': 'gemma3:4b'},
                ],
              }),
            '/api/show' => json({
                'capabilities': jsonDecode(r.body)['model'] == 'gemma3:4b' ? ['completion', 'vision'] : ['completion', 'tools'],
              }),
            '/v1/models' => json({
                'data': [
                  {'id': 'claude-opus-5-5'},
                ],
              }),
            _ => json({}, 404),
          });
      final ollama = await AiClient.of(AiProviderKind.ollama, baseUrl: 'http://localhost:11434', client: fake.client()).listModels();
      expect(ollama.map((m) => (m.id, m.vision, m.tools)), [('gemma3:4b', true, false), ('qwen3:8b', false, true)]);
      final claude = await AiClient.of(AiProviderKind.anthropic, baseUrl: 'https://api.anthropic.com', apiKey: 'k', client: fake.client()).listModels();
      expect(claude.single.id, 'claude-opus-5-5');
    });

    test('errors are explained', () async {
      final fake = Fake((_) => json({'error': {'message': 'invalid x-api-key'}}, 401));
      final client = AiClient.of(AiProviderKind.anthropic, baseUrl: 'https://api.anthropic.com', apiKey: 'bad', client: fake.client());
      expect(() => client.send(request), throwsA(isA<AiException>().having((e) => e.message, 'message', contains('Check the API key'))));
      final down = AiClient.of(AiProviderKind.ollama, baseUrl: 'http://localhost:11434', client: MockClient((_) => throw Exception('refused')));
      expect(() => down.send(request), throwsA(isA<AiException>().having((e) => e.message, 'message', contains('Is it running'))));
    });
  });

  group('settings', () {
    test('setups are saved; keys go to secure storage, not with the setups', () async {
      final store = MemoryAiSettingsStore();
      final s = AiSettings(store);
      await s.load();
      final setup = AiSetup(id: 'x', name: 'Claude', kind: AiProviderKind.anthropic, baseUrl: 'https://api.anthropic.com', quickModel: 'q', strongModel: 's');
      await s.save(setup, key: 'sk-secret', keyChanged: true);
      expect(store.setups, isNot(contains('sk-secret')));
      expect(store.keys['x'], 'sk-secret');
      final again = AiSettings(store);
      await again.load();
      expect(again.active!.name, 'Claude');
      expect(again.keyFor(again.active!), 'sk-secret');
      await again.remove(again.active!);
      expect(store.keys, isEmpty);
    });

    test('which models can see pictures', () {
      final claude = AiSetup(id: 'a', name: '', kind: AiProviderKind.anthropic, baseUrl: '');
      final ollama = AiSetup(id: 'b', name: '', kind: AiProviderKind.ollama, baseUrl: '', visionModels: {'mystery:1b'});
      expect(claude.canSeeImages('claude-haiku-5-5'), isTrue);
      expect(ollama.canSeeImages('mystery:1b'), isTrue);
      expect(ollama.canSeeImages('qwen3:8b'), isFalse);
      expect(ollama.canSeeImages('llava:7b'), isTrue);
      expect((ollama..vision = false).canSeeImages('llava:7b'), isFalse);
    });
  });

  group('edits', () {
    test('the brief names every element, with shapes, styles and the selection', () {
      final c = sample();
      c.select(c.drawing.allElements.elementAt(1));
      final brief = DrawingBrief.of(c);
      final j = jsonDecode(brief.json) as Map<String, dynamic>;
      final els = (j['layers'] as List).single['elements'] as List;
      expect(els.map((e) => e['shape']), ['rectangle', 'ellipse', 'line']);
      expect(els.first['fill'], '#ff0000');
      expect(els.first['box'], [10, 10, 50, 50]);
      expect(j['selected'], ['e2']);
      expect(brief.byId['e3'], isA<InkPath>());
    });

    test('operations apply as one undo step; bad ones are reported', () {
      final c = sample();
      final brief = DrawingBrief.of(c);
      final [rect, oval, line] = c.drawing.allElements.toList();
      final result = applyEdits(c, brief, {
        'summary': 'Did things',
        'operations': [
          {'op': 'fill', 'ids': ['e1'], 'color': 'gold'},
          {'op': 'fill', 'ids': ['e2'], 'gradient': {'type': 'linear', 'colors': ['#ff0000', '#0000ff'], 'angle': 90}},
          {'op': 'stroke', 'ids': ['e3'], 'color': '#00ff00', 'width': 4, 'end_arrow': 'Chubby Arrow'},
          {'op': 'move', 'ids': ['e1'], 'dx': 5, 'dy': 0},
          {'op': 'resize', 'ids': ['e2'], 'width': 100},
          {'op': 'shadow', 'ids': ['e1'], 'blur': 8},
          {'op': 'fill', 'ids': ['e99'], 'color': 'red'},
          {'op': 'teleport', 'ids': ['e1']},
        ],
      });
      expect(result.applied, 6);
      expect(result.problems, containsAll(['Unknown element e99', 'Unknown operation teleport']));
      expect((rect as InkPath).fill, const InkColor(1, 215 / 255, 0));
      expect(rect.bounds.left, 15);
      expect(rect.shadow!.radius, 8);
      final g = (oval as InkPath).fill as InkGradient;
      expect(g.geometry!.documentStart.dy, lessThan(g.geometry!.documentEnd.dy)); // top to bottom
      expect(oval.bounds.width, closeTo(100, 0.01));
      expect(oval.bounds.height, closeTo(100, 0.01)); // kept its proportions
      expect(((line as InkPath).stroke!.endArrow, line.stroke!.width), ('chubby arrow', 4));
      c.undo();
      expect((c.drawing.allElements.first as InkPath).fill, red); // all in one step
      expect(c.canUndo, isFalse);
    });

    test('align, group, delete inside groups, text and new artwork', () {
      final c = sample();
      c.addElement(InkText(text: 'Hello', fontFamily: 'Lato'));
      var brief = DrawingBrief.of(c);
      applyEdits(c, brief, {
        'summary': '',
        'operations': [
          {'op': 'align', 'ids': ['e1', 'e2'], 'edge': 'top'},
          {'op': 'text', 'ids': ['e4'], 'text': 'Goodbye'},
          {'op': 'font', 'ids': ['e4'], 'size': 40, 'style': 'Bold'},
          {'op': 'group', 'ids': ['e1', 'e2']},
          {
            'op': 'add_svg',
            'svg': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="5" fill="green"/></svg>',
            'x': 300, 'y': 300, 'width': 50, 'height': 50,
          },
        ],
      });
      final els = c.drawing.activeLayer.elements;
      expect(els.whereType<InkGroup>().single.elements.length, 2);
      final t = els.whereType<InkText>().single;
      expect((t.text, t.fontSize, t.fontStyle), ('Goodbye', 40, 'Bold'));
      final added = els.last;
      expect(added.bounds.left, closeTo(300, 0.5));
      expect(added.bounds.width, closeTo(50, 0.5));

      brief = DrawingBrief.of(c);
      final inner = brief.byId.entries.firstWhere((e) => e.value is InkPath && (e.value as InkPath).fill == blue).key;
      applyEdits(c, brief, {'summary': '', 'operations': [{'op': 'delete', 'ids': [inner]}]});
      expect(c.drawing.activeLayer.elements.whereType<InkGroup>().single.elements.length, 1);
    });
  });

  group('assistant', () {
    test('edit: uses the quick model, sends the drawing, applies the answer', () async {
      final fake = Fake((_) => claudeEdits('Made the square blue.', [
            {'op': 'fill', 'ids': ['e1'], 'color': '#0000ff'},
          ]));
      final c = sample();
      final a = AiAssistant(c, await settingsWith(fake, AiProviderKind.anthropic));
      final out = await a.run(AiMode.edit, 'make the square blue');
      expect(fake.lastBody['model'], 'small');
      expect(fake.lastBody['messages'].last['content'].last['text'], contains('"shape":"rectangle"'));
      expect(out.summary, 'Made the square blue.');
      expect((c.drawing.allElements.first as InkPath).fill, blue);
      expect(out.reply.text, contains('"operations"'));
    });

    test('edit: a model that can\'t use tools is asked again for JSON', () async {
      var calls = 0;
      final fake = Fake((r) {
        calls++;
        final body = jsonDecode(r.body) as Map;
        if (body.containsKey('tools')) return json({'error': 'registry.ollama.ai/library/tiny does not support tools'}, 400);
        return json({'message': {'content': '{"summary": "Moved it.", "operations": [{"op": "move", "ids": ["e1"], "dx": 10}]}'}});
      });
      final c = sample();
      final out = await AiAssistant(c, await settingsWith(fake, AiProviderKind.ollama)).run(AiMode.edit, 'move the square right');
      expect(calls, 2);
      expect(out.summary, 'Moved it.');
      expect(c.drawing.allElements.first.bounds.left, 20);
    });

    test('draw: uses the drawing model and places the SVG in the selected area', () async {
      final fake = Fake((_) => json({
            'content': [
              {
                'type': 'text',
                'text': '```svg\n<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><rect width="100" height="50" fill="#123456"/></svg>\n```\nA navy banner.',
              },
            ],
          }));
      final c = DrawingController();
      final frame = InkPath.rect(const Rect.fromLTWH(100, 100, 200, 200));
      c.addElement(frame);
      c.select(frame);
      final out = await AiAssistant(c, await settingsWith(fake, AiProviderKind.anthropic)).run(AiMode.draw, 'a banner');
      expect(fake.lastBody['model'], 'big');
      expect(fake.lastBody.containsKey('tools'), isFalse);
      expect(out.summary, 'A navy banner.');
      final art = c.drawing.activeLayer.elements.last;
      expect(art.bounds.width, closeTo(200, 0.5)); // fitted to the area, proportions kept
      expect(art.bounds.center.dy, closeTo(200, 0.5));
      c.undo();
      expect(c.drawing.activeLayer.elements.length, 1);
    });

    test('svgIn finds fenced or bare SVG', () {
      expect(svgIn('x <svg a="1"></svg> y'), '<svg a="1"></svg>');
      expect(svgIn('```svg\n<svg></svg>\n```'), '<svg></svg>');
      expect(svgIn('no art'), isNull);
    });
  });

  testWidgets('the ✨ panel: ask, preview, undo, follow up, keep', (tester) async {
    var answer = 0;
    final fake = Fake((_) => claudeEdits('Changed it (${++answer}).', [
          {'op': 'fill', 'ids': ['e1'], 'color': answer == 1 ? '#00ff00' : '#ffff00'},
        ]));
    final settings = await settingsWith(fake, AiProviderKind.anthropic);
    final c = sample();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AiPanel(controller: c, settings: settings)))));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'make the square green');
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(find.text('Changed it (1).'), findsOneWidget);
    expect((c.drawing.allElements.first as InkPath).fill, const InkColor(0, 1, 0));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect((c.drawing.allElements.first as InkPath).fill, red);

    // Ask again, then follow up: the first try is replaced, with the chat as context.
    await tester.enterText(find.byType(TextField), 'make the square green');
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'yellow instead');
    await tester.tap(find.text('Redo'));
    await tester.pumpAndSettle();
    expect((c.drawing.allElements.first as InkPath).fill, const InkColor(1, 1, 0));
    final messages = fake.lastBody['messages'] as List;
    expect(messages.length, 3); // asked, answered, follow-up
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    c.undo();
    expect((c.drawing.allElements.first as InkPath).fill, red); // one step for the kept change
  });

  testWidgets('without a service the panel offers to set one up', (tester) async {
    final settings = AiSettings(MemoryAiSettingsStore());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AiPanel(controller: DrawingController(), settings: settings))));
    await tester.pumpAndSettle();
    expect(find.text('Set up AI…'), findsOneWidget);
  });
}
