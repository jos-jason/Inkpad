import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inkpad/ai/ai_client.dart';
import 'package:inkpad/ai/ai_settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('API keys round-trip through the device\'s secure storage', (tester) async {
    final store = DeviceAiSettingsStore();
    await store.writeKey('keychain-check', 'sk-test-value');
    expect(await store.readKey('keychain-check'), 'sk-test-value');
    await store.writeKey('keychain-check', null);
    expect(await store.readKey('keychain-check'), isNull);
    await store.writeSetups('{"setups": []}');
    expect(await store.readSetups(), '{"setups": []}');
  });

  testWidgets('the sandboxed app can reach an AI service', (tester) async {
    // No key is sent: the service answers that it needs one, which proves
    // the connection itself works.
    final client = AiClient.of(AiProviderKind.anthropic, baseUrl: 'https://api.anthropic.com');
    await expectLater(client.listModels(), throwsA(isA<AiException>().having((e) => e.message, 'message', isNot(contains('Could not reach')))));
    client.close();
  });
}
