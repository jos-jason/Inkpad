import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The kinds of AI service Inkpad can talk to. Each brings its own key
/// (except a local Ollama).
enum AiProviderKind {
  anthropic('Claude (Anthropic)', 'https://api.anthropic.com'),
  openAi('OpenAI-compatible', 'https://api.openai.com/v1'),
  ollama('Ollama', 'http://localhost:11434');

  final String label;
  final String defaultBaseUrl;

  const AiProviderKind(this.label, this.defaultBaseUrl);

  bool get needsKey => this == anthropic;
}

/// An action the model may call, described by a JSON schema.
class AiTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const AiTool(this.name, this.description, this.parameters);
}

/// One message of a conversation: text, optionally with a picture.
class AiMessage {
  final bool fromUser;
  final String text;

  /// A PNG for models that can see images (user messages only).
  final Uint8List? image;

  const AiMessage.user(this.text, {this.image}) : fromUser = true;
  const AiMessage.assistant(this.text)
      : fromUser = false,
        image = null;
}

class AiRequest {
  final String model;
  final String system;
  final List<AiMessage> messages;

  /// Offered to the model; if [forceTool] it should answer by calling it.
  final AiTool? tool;
  final bool forceTool;
  final int maxTokens;

  const AiRequest({
    required this.model,
    required this.system,
    required this.messages,
    this.tool,
    this.forceTool = true,
    this.maxTokens = 4096,
  });
}

/// The model's answer: its text, and the arguments it passed to the tool
/// (if it called it).
class AiResponse {
  final String text;
  final Map<String, dynamic>? toolArguments;

  const AiResponse(this.text, [this.toolArguments]);
}

class AiException implements Exception {
  final String message;

  const AiException(this.message);

  @override
  String toString() => message;
}

/// What a model can do, as far as the service says.
class AiModelInfo {
  final String id;
  final bool? vision;
  final bool? tools;

  const AiModelInfo(this.id, {this.vision, this.tools});
}

/// Talks to one AI service. Requests go straight from the app to the
/// service with the user's own key; nothing goes through a server of ours.
abstract class AiClient {
  final String baseUrl;
  final String? apiKey;
  final http.Client _http;

  AiClient(String baseUrl, this.apiKey, http.Client? client)
      : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http = client ?? http.Client();

  factory AiClient.of(AiProviderKind kind, {required String baseUrl, String? apiKey, http.Client? client}) => switch (kind) {
        AiProviderKind.anthropic => AnthropicClient(baseUrl, apiKey, client),
        AiProviderKind.openAi => OpenAiClient(baseUrl, apiKey, client),
        AiProviderKind.ollama => OllamaClient(baseUrl, apiKey, client),
      };

  Future<AiResponse> send(AiRequest request);

  Future<List<AiModelInfo>> listModels();

  /// Stops any request in progress (it then fails with an AiException).
  void close() => _http.close();

  Map<String, String> get headers;

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final http.Response r;
    try {
      r = await _http.post(Uri.parse('$baseUrl$path'), headers: {...headers, 'content-type': 'application/json'}, body: jsonEncode(body));
    } catch (e) {
      throw AiException(_connectionHelp(e));
    }
    return _decode(r);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final http.Response r;
    try {
      r = await _http.get(Uri.parse('$baseUrl$path'), headers: headers);
    } catch (e) {
      throw AiException(_connectionHelp(e));
    }
    return _decode(r);
  }

  String _connectionHelp(Object e) {
    final local = baseUrl.contains('localhost') || baseUrl.contains('127.0.0.1') || RegExp(r'//(10|192\.168|172)\.').hasMatch(baseUrl);
    final hint = local
        ? ' Is it running, and reachable from this device? (For Ollama on another computer, start it with OLLAMA_HOST=0.0.0.0'
            '${kIsWeb ? ' and OLLAMA_ORIGINS=*' : ''}.)'
        : kIsWeb
            ? ' Some services can\'t be reached from a web browser.'
            : '';
    return 'Could not reach $baseUrl.$hint ($e)';
  }

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (r.statusCode >= 300) {
      final err = j?['error'];
      final msg = err is Map ? err['message'] : err;
      final text = msg?.toString() ?? utf8.decode(r.bodyBytes, allowMalformed: true);
      throw AiException(switch (r.statusCode) {
        401 || 403 => 'The service refused the key ($text). Check the API key in AI settings.',
        404 => 'Not found ($text). Check the address and model name.',
        429 => 'The service is busy or over its limit; try again shortly. ($text)',
        _ => 'The service said: $text (${r.statusCode})',
      });
    }
    if (j == null) throw const AiException('The service sent back something unreadable.');
    return j;
  }
}

/// Claude, via Anthropic's Messages API.
class AnthropicClient extends AiClient {
  AnthropicClient(super.baseUrl, super.apiKey, super.client);

  @override
  Map<String, String> get headers => {
        'x-api-key': ?apiKey,
        'anthropic-version': '2023-06-01',
        // Allowed by Anthropic for apps where the user brings their own key.
        if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
      };

  @override
  Future<AiResponse> send(AiRequest q) async {
    final tool = q.tool;
    final j = await _post('/v1/messages', {
      'model': q.model,
      'max_tokens': q.maxTokens,
      'system': q.system,
      'messages': [
        for (final m in q.messages)
          {
            'role': m.fromUser ? 'user' : 'assistant',
            'content': [
              if (m.image != null)
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': 'image/png', 'data': base64Encode(m.image!)},
                },
              {'type': 'text', 'text': m.text},
            ],
          },
      ],
      if (tool != null) ...{
        'tools': [
          {'name': tool.name, 'description': tool.description, 'input_schema': tool.parameters},
        ],
        if (q.forceTool) 'tool_choice': {'type': 'tool', 'name': tool.name},
      },
    });
    final text = StringBuffer();
    Map<String, dynamic>? args;
    for (final block in (j['content'] as List? ?? const [])) {
      if (block['type'] == 'text') text.write(block['text']);
      if (block['type'] == 'tool_use' && block['input'] is Map) args = Map<String, dynamic>.from(block['input']);
    }
    return AiResponse(text.toString(), args);
  }

  @override
  Future<List<AiModelInfo>> listModels() async {
    final j = await _get('/v1/models?limit=100');
    // Every current Claude model can see images and use tools.
    return [for (final m in (j['data'] as List? ?? const [])) AiModelInfo(m['id'] as String, vision: true, tools: true)];
  }
}

/// OpenAI's Chat Completions API, which many services also offer (OpenRouter,
/// Groq, Mistral, LM Studio, Gemini's compatible endpoint, Ollama's /v1).
class OpenAiClient extends AiClient {
  OpenAiClient(super.baseUrl, super.apiKey, super.client);

  @override
  Map<String, String> get headers => {if (apiKey != null && apiKey!.isNotEmpty) 'authorization': 'Bearer $apiKey'};

  @override
  Future<AiResponse> send(AiRequest q) async {
    final tool = q.tool;
    final j = await _post('/chat/completions', {
      'model': q.model,
      'max_tokens': q.maxTokens,
      'messages': [
        {'role': 'system', 'content': q.system},
        for (final m in q.messages)
          m.image == null
              ? {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text}
              : {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': m.text},
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:image/png;base64,${base64Encode(m.image!)}'},
                    },
                  ],
                },
      ],
      if (tool != null) ...{
        'tools': [
          {
            'type': 'function',
            'function': {'name': tool.name, 'description': tool.description, 'parameters': tool.parameters},
          },
        ],
        if (q.forceTool)
          'tool_choice': {
            'type': 'function',
            'function': {'name': tool.name},
          },
      },
    });
    final message = ((j['choices'] as List?)?.firstOrNull as Map?)?['message'] as Map?;
    if (message == null) throw const AiException('The service sent back no answer.');
    Map<String, dynamic>? args;
    final calls = message['tool_calls'] as List?;
    if (calls != null && calls.isNotEmpty) {
      final raw = calls.first['function']?['arguments'];
      args = raw is String ? _jsonObject(raw) : (raw is Map ? Map<String, dynamic>.from(raw) : null);
    }
    return AiResponse(message['content'] as String? ?? '', args);
  }

  @override
  Future<List<AiModelInfo>> listModels() async {
    final j = await _get('/models');
    return [for (final m in (j['data'] as List? ?? const [])) AiModelInfo(m['id'] as String)]..sort((a, b) => a.id.compareTo(b.id));
  }
}

/// A local (or self-hosted) Ollama, via its own chat API.
class OllamaClient extends AiClient {
  OllamaClient(super.baseUrl, super.apiKey, super.client);

  @override
  Map<String, String> get headers => {if (apiKey != null && apiKey!.isNotEmpty) 'authorization': 'Bearer $apiKey'};

  @override
  Future<AiResponse> send(AiRequest q) async {
    final tool = q.tool;
    final j = await _post('/api/chat', {
      'model': q.model,
      'stream': false,
      'options': {'num_predict': q.maxTokens},
      'messages': [
        {'role': 'system', 'content': q.system},
        for (final m in q.messages)
          {
            'role': m.fromUser ? 'user' : 'assistant',
            'content': m.text,
            if (m.image != null) 'images': [base64Encode(m.image!)],
          },
      ],
      if (tool != null)
        'tools': [
          {
            'type': 'function',
            'function': {'name': tool.name, 'description': tool.description, 'parameters': tool.parameters},
          },
        ],
    });
    final message = j['message'] as Map?;
    if (message == null) throw const AiException('Ollama sent back no answer.');
    Map<String, dynamic>? args;
    final calls = message['tool_calls'] as List?;
    if (calls != null && calls.isNotEmpty) {
      final raw = calls.first['function']?['arguments'];
      args = raw is String ? _jsonObject(raw) : (raw is Map ? Map<String, dynamic>.from(raw) : null);
    }
    return AiResponse(message['content'] as String? ?? '', args);
  }

  @override
  Future<List<AiModelInfo>> listModels() async {
    final j = await _get('/api/tags');
    final names = [for (final m in (j['models'] as List? ?? const [])) m['name'] as String]..sort();
    // Newer Ollama versions say what each model can do.
    final out = <AiModelInfo>[];
    for (final n in names) {
      try {
        final show = await _post('/api/show', {'model': n});
        final caps = (show['capabilities'] as List?)?.cast<String>();
        out.add(AiModelInfo(n, vision: caps?.contains('vision'), tools: caps?.contains('tools')));
      } catch (_) {
        out.add(AiModelInfo(n));
      }
    }
    return out;
  }
}

/// A JSON object from [text]: the whole text, a fenced ```json block, or
/// the outermost {...} in it. Null if there isn't one. (For models that
/// answer in text instead of calling the tool.)
Map<String, dynamic>? _jsonObject(String text) {
  Map<String, dynamic>? tryParse(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  final direct = tryParse(text.trim());
  if (direct != null) return direct;
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) {
    final f = tryParse(fence.group(1)!.trim());
    if (f != null) return f;
  }
  final start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start >= 0 && end > start) return tryParse(text.substring(start, end + 1));
  return null;
}

/// Public for the features that fall back to JSON in text.
Map<String, dynamic>? jsonObjectIn(String text) => _jsonObject(text);
