import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  test('ProviderProfile preserves streamIdleTimeoutMs in both directions', () {
    const profile = ProviderProfile(
      route: 'magpie',
      api: 'openai-completions',
      baseUrl: 'http://127.0.0.1:3425/v1',
      streamIdleTimeoutMs: 600000,
    );
    expect(profile.toJson()['streamIdleTimeoutMs'], 600000);
    final read = ProviderProfile.fromJson('magpie', profile.toJson());
    expect(read.streamIdleTimeoutMs, 600000);
  });

  test('updateProvider sends streamIdleTimeoutMs alongside other changes', () async {
    final host = await FakeDsh.start();
    addTearDown(host.close);
    final mutations = <Map<String, Object?>>[];
    host.handlers['settings/mutate'] = (args) {
      mutations.add(args);
      return {'ok': true, 'value': {
        'ns': 'llm-pi-ai',
        'revision': 5,
        'value': {'providers': <String, Object?>{}},
        'user': {'providers': <String, Object?>{}},
        'base': {'providers': <String, Object?>{}},
      }};
    };
    final client = await DshClient.connect(
      baseUri: host.baseUri,
      token: FakeDsh.token,
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2)),
    );
    addTearDown(client.close);
    await client.updateProvider('magpie', streamIdleTimeoutMs: 600000, expectedRevision: 4);
    expect(mutations.single, {
      'ns': 'llm-pi-ai',
      'ops': [
        {
          'op': 'set',
          'path': ['providers', 'magpie', 'streamIdleTimeoutMs'],
          'value': 600000,
        },
      ],
      'expectedRevision': 4,
    });
  });
}
