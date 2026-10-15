import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_client.dart';

/// One saved AI service: where it is, and which models to use. The key is
/// kept apart, in the device's secure storage.
class AiSetup {
  final String id;
  String name;
  AiProviderKind kind;
  String baseUrl;

  /// A fast, cheap model for quick edits.
  String quickModel;

  /// A stronger model for drawing from a description.
  String strongModel;

  /// Whether the models can see a picture of the drawing (null: decide
  /// from what the service says, or the model's name).
  bool? vision;

  /// Models the service said can see images (from the last model list).
  Set<String> visionModels;

  AiSetup({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.quickModel = '',
    this.strongModel = '',
    this.vision,
    Set<String>? visionModels,
  }) : visionModels = visionModels ?? {};

  /// Suggested models for a new setup of [kind].
  static (String quick, String strong) defaultModels(AiProviderKind kind) => switch (kind) {
        AiProviderKind.anthropic => ('claude-haiku-5-5', 'claude-opus-5-5'),
        AiProviderKind.openAi => ('', ''),
        AiProviderKind.ollama => ('', ''),
      };

  bool get isComplete => baseUrl.isNotEmpty && quickModel.isNotEmpty && strongModel.isNotEmpty;

  /// Whether [model] can be shown a picture of the drawing.
  bool canSeeImages(String model) {
    final v = vision;
    if (v != null) return v;
    if (kind == AiProviderKind.anthropic) return true;
    if (visionModels.contains(model)) return true;
    final m = model.toLowerCase();
    return const ['gpt-4o', 'gpt-4.1', 'gpt-5', 'vision', 'vl', 'llava', 'gemini', 'claude', 'gemma3', 'pixtral', 'llama4']
        .any(m.contains);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'baseUrl': baseUrl,
        'quick': quickModel,
        'strong': strongModel,
        if (vision != null) 'vision': vision,
        if (visionModels.isNotEmpty) 'visionModels': visionModels.toList(),
      };

  factory AiSetup.fromJson(Map<String, dynamic> j) => AiSetup(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'AI',
        kind: AiProviderKind.values.asNameMap()[j['kind']] ?? AiProviderKind.anthropic,
        baseUrl: j['baseUrl'] as String? ?? '',
        quickModel: j['quick'] as String? ?? '',
        strongModel: j['strong'] as String? ?? '',
        vision: j['vision'] as bool?,
        visionModels: {...((j['visionModels'] as List?) ?? const []).cast<String>()},
      );
}

/// Where setups and keys are kept.
abstract class AiSettingsStore {
  Future<String?> readSetups();
  Future<void> writeSetups(String json);
  Future<String?> readKey(String setupId);
  Future<void> writeKey(String setupId, String? key);
}

/// Setups in app preferences; keys in the Keychain (Apple), Keystore
/// (Android), the system keyring (Linux) or Credential Manager (Windows).
class DeviceAiSettingsStore implements AiSettingsStore {
  final _prefs = SharedPreferencesAsync();
  static const _secure = FlutterSecureStorage(
    // The classic keychain works in the sandboxed Mac app without extra
    // signing entitlements.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> readSetups() => _prefs.getString('ai.setups');

  @override
  Future<void> writeSetups(String json) => _prefs.setString('ai.setups', json);

  @override
  Future<String?> readKey(String setupId) => _secure.read(key: 'ai.key.$setupId');

  @override
  Future<void> writeKey(String setupId, String? key) => key == null || key.isEmpty
      ? _secure.delete(key: 'ai.key.$setupId')
      : _secure.write(key: 'ai.key.$setupId', value: key);
}

/// For tests.
class MemoryAiSettingsStore implements AiSettingsStore {
  String? setups;
  final Map<String, String> keys = {};

  @override
  Future<String?> readSetups() async => setups;

  @override
  Future<void> writeSetups(String json) async => setups = json;

  @override
  Future<String?> readKey(String setupId) async => keys[setupId];

  @override
  Future<void> writeKey(String setupId, String? key) async => key == null || key.isEmpty ? keys.remove(setupId) : keys[setupId] = key;
}

/// The AI setups and which one is in use.
class AiSettings extends ChangeNotifier {
  static AiSettings instance = AiSettings(DeviceAiSettingsStore());

  final AiSettingsStore store;

  /// Lets tests answer requests without a network.
  http.Client Function()? httpClient;

  AiSettings(this.store, {this.httpClient});

  List<AiSetup> setups = [];
  String? activeId;
  bool loaded = false;
  final Map<String, String> _keys = {};

  /// Set when keys couldn't be read or saved securely.
  String? keyStoreProblem;

  AiSetup? get active => setups.where((s) => s.id == activeId).firstOrNull ?? setups.firstOrNull;

  Future<void> load() async {
    if (loaded) return;
    try {
      final raw = await store.readSetups();
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        setups = [for (final s in (j['setups'] as List? ?? const [])) AiSetup.fromJson(s as Map<String, dynamic>)];
        activeId = j['active'] as String?;
      }
    } catch (e) {
      debugPrint('Could not read AI settings: $e');
    }
    for (final s in setups) {
      try {
        final k = await store.readKey(s.id);
        if (k != null) _keys[s.id] = k;
      } catch (e) {
        keyStoreProblem = 'Could not read saved API keys: $e';
      }
    }
    loaded = true;
    notifyListeners();
  }

  String? keyFor(AiSetup s) => _keys[s.id];

  Future<void> _saveSetups() async {
    await store.writeSetups(jsonEncode({'setups': [for (final s in setups) s.toJson()], 'active': activeId}));
    notifyListeners();
  }

  Future<void> save(AiSetup setup, {String? key, bool keyChanged = false}) async {
    if (!setups.contains(setup)) setups.add(setup);
    activeId ??= setup.id;
    if (keyChanged) {
      try {
        await store.writeKey(setup.id, key);
        keyStoreProblem = null;
      } catch (e) {
        keyStoreProblem = 'Could not save the API key securely: $e';
      }
      if (key == null || key.isEmpty) {
        _keys.remove(setup.id);
      } else {
        _keys[setup.id] = key;
      }
    }
    await _saveSetups();
  }

  Future<void> remove(AiSetup setup) async {
    setups.remove(setup);
    _keys.remove(setup.id);
    try {
      await store.writeKey(setup.id, null);
    } catch (_) {}
    if (activeId == setup.id) activeId = setups.firstOrNull?.id;
    await _saveSetups();
  }

  Future<void> use(AiSetup setup) async {
    activeId = setup.id;
    await _saveSetups();
  }

  /// A client for [setup] (or the active one).
  AiClient clientFor(AiSetup setup) =>
      AiClient.of(setup.kind, baseUrl: setup.baseUrl, apiKey: keyFor(setup), client: httpClient?.call());
}
