import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/links/magpie_links.dart';
import 'package:dsh_app/state/magpie_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('splits native Responses, Anthropic and Chat models into three routes', () {
    const models = [
      DiscoveredModel(id: 'chat'),
      DiscoveredModel(id: 'responses'),
      DiscoveredModel(id: 'messages'),
    ];
    final grouped = groupMagpieModels(models, {
      'chat': {'native_endpoints': ['/v1/chat/completions']},
      'responses': {'native_endpoints': ['/v1/responses']},
      'messages': {'native_endpoints': ['/v1/messages']},
    });
    expect(grouped[MagpieRouteKind.completions]!.map((m) => m.id), ['chat']);
    expect(grouped[MagpieRouteKind.responses]!.map((m) => m.id), ['responses']);
    expect(grouped[MagpieRouteKind.anthropic]!.map((m) => m.id), ['messages']);
  });

  test('keeps compat and output cap while refreshing reasoning and size limits', () {
    const previous = ProviderModelSpec(
      id: 'model',
      maxTokens: 12345,
      extra: {'compat': {'supportsStrictMode': true}},
    );
    const discovered = DiscoveredModel(
      id: 'model',
      contextWindow: 500000,
      maxTokens: 500000,
      inputModalities: ['text', 'image'],
    );
    final spec = magpieModelSpec(
      discovered,
      metadata: {
        'supported_reasoning_levels': [
          {'effort': 'none'},
          {'effort': 'low'},
          {'effort': 'high'},
        ],
      },
      previous: previous,
    );
    expect(spec.maxTokens, 12345);
    expect(spec.extra['compat'], {'supportsStrictMode': true});
    expect(spec.reasoningEfforts, {'off': null, 'low': 'low', 'high': 'high'});
    expect(spec.input, ['text', 'image']);
  });

  test('caps output to preserve DSH compaction headroom', () {
    const discovered = DiscoveredModel(id: 'model', contextWindow: 500000, maxTokens: 500000);
    final spec = magpieModelSpec(discovered);
    expect(spec.maxTokens, 184464);
  });

  test('seeds Responses strict mode and adaptive Anthropic compat', () {
    const models = [
      DiscoveredModel(id: 'codex/gpt-6.1-sol'),
      DiscoveredModel(id: 'copilot/claude-opus-5-5'),
      DiscoveredModel(id: 'zcode/GLM-5.3-Flash'),
      DiscoveredModel(id: 'claude-sonnet-4-5'),
    ];
    final grouped = groupMagpieModels(models, {
      'codex/gpt-6.1-sol': {'native_endpoints': ['/v1/responses']},
      'copilot/claude-opus-5-5': {'native_endpoints': ['/v1/messages']},
      'zcode/GLM-5.3-Flash': {'native_endpoints': ['/v1/messages']},
      'claude-sonnet-4-5': {'native_endpoints': ['/v1/messages']},
    });
    expect(grouped[MagpieRouteKind.responses]!.single.extra['compat'], {'supportsStrictMode': true});
    expect(grouped[MagpieRouteKind.anthropic]![0].extra['compat'], {'forceAdaptiveThinking': true});
    expect(grouped[MagpieRouteKind.anthropic]![1].extra['compat'], {'forceAdaptiveThinking': true});
    expect(grouped[MagpieRouteKind.anthropic]![2].extra['compat'], isNull);
  });

  test('recognizes Claude versions and adaptive effort models', () {
    expect(adaptiveClaudeModel('claude-opus-5-5'), isTrue);
    expect(adaptiveClaudeModel('anthropic.claude-sonnet-4.6-v1'), isTrue);
    // The gateway's claudeVersion also reads the version-first spelling.
    expect(adaptiveClaudeModel('claude-5-sonnet'), isTrue);
    expect(adaptiveClaudeModel('claude-sonnet-4-5'), isFalse);
    expect(adaptiveClaudeModel('claude-3-7-sonnet'), isFalse);
    expect(adaptiveThinkingModel('zcode/GLM-5.3-Flash'), isTrue);
    expect(adaptiveThinkingModel('deepseek-v4.1-flash'), isFalse);
  });

  test('keeps compat only while the route resolves to the same api', () {
    const previous = ProviderModelSpec(
      id: 'model',
      extra: {'compat': {'supportsStrictMode': true, 'maxTokensField': 'max_tokens'}},
    );
    const model = DiscoveredModel(id: 'model');
    // Same api: the user's own switches ride along.
    final same = magpieModelSpec(model, previous: previous, api: 'openai-responses', previousApi: 'openai-responses');
    expect(same.extra['compat'], {'supportsStrictMode': true, 'maxTokensField': 'max_tokens'});
    // A protocol change starts the model without them, then magpie's own
    // switches go on the api the route has — not on the kind's name.
    final moved = magpieModelSpec(
      model,
      previous: previous,
      api: 'anthropic-messages',
      previousApi: 'openai-responses',
    );
    expect(moved.extra['compat'], isNull);
    final userPicked = magpieModelSpec(
      model,
      route: MagpieRouteKind.completions,
      api: 'openai-responses',
      previousApi: 'openai-completions',
    );
    expect(userPicked.extra['compat'], {'supportsStrictMode': true});
  });

  test('resolves the route api the way the desktop importer does', () {
    expect(magpieApiFor(MagpieRouteKind.completions, 'openai-responses'), ProviderApi.openaiResponses);
    expect(magpieApiFor(MagpieRouteKind.completions, 'something-foreign'), ProviderApi.openaiCompletions);
    expect(magpieApiFor(MagpieRouteKind.anthropic, null), ProviderApi.anthropicMessages);
    expect(magpieBaseUrlFor(ProviderApi.anthropicMessages), 'http://127.0.0.1:3425');
    expect(magpieBaseUrlFor(ProviderApi.openaiCompletions), 'http://127.0.0.1:3425/v1');
  });

  test('preserves automatic routing ids separately from provider ids', () {
    const models = [
      DiscoveredModel(id: 'auto/glm-5.3-flash'),
      DiscoveredModel(id: 'volcengine/glm-5.3-flash'),
      DiscoveredModel(id: 'auto/claude-opus-5-5'),
    ];
    final grouped = groupMagpieModels(models, {
      'auto/glm-5.3-flash': {'owned_by': 'volcengine'},
      'volcengine/glm-5.3-flash': {},
      'auto/claude-opus-5-5': {'owned_by': 'copilot', 'native_endpoints': ['/v1/messages']},
    });
    expect(grouped[MagpieRouteKind.completions]!.map((m) => m.id), ['auto/glm-5.3-flash', 'volcengine/glm-5.3-flash']);
    expect(grouped[MagpieRouteKind.anthropic]!.single.id, 'auto/claude-opus-5-5');
  });

  test('reads rich modalities and native reasoning names', () {
    const model = DiscoveredModel(id: 'vision');
    final spec = magpieModelSpec(model, metadata: {
      'modalities': {'input': ['text', 'image', 'video']},
      'supported_reasoning_levels': [
        {'effort': 'none'},
        {'effort': 'light'},
        {'effort': 'extra_high'},
        {'effort': 'ultra'},
      ],
    });
    expect(spec.input, ['text', 'image']);
    // Wire values keep the gateway's own effort names, not the dsh level keys.
    expect(spec.reasoningEfforts, {'off': null, 'low': 'light', 'xhigh': 'extra_high', 'max': 'ultra'});
  });

  test('bare string level lists and off-only levels are handled', () {
    const model = DiscoveredModel(id: 'legacy');
    final bare = magpieModelSpec(model, metadata: {
      'reasoning_levels': ['none', 'low', 'high'],
    });
    expect(bare.reasoningEfforts, {'off': null, 'low': 'low', 'high': 'high'});

    // A model that only ever thinks at one unnamed level gets an off-only
    // list; llm-pi-ai rejects that map, so it is written as non-reasoning.
    final offOnly = magpieModelSpec(model, metadata: {
      'supported_reasoning_levels': [
        {'effort': 'none'},
      ],
    });
    expect(offOnly.extra['reasoningEfforts'], false);
    expect(offOnly.reasoningEfforts, isNull);

    // An explicit empty list disables reasoning instead of leaving the field.
    final none = magpieModelSpec(model, metadata: {'reasoning_levels': []});
    expect(none.extra['reasoningEfforts'], false);

    // Metadata without level fields keeps what the user already has.
    const withLevels = ProviderModelSpec(
      id: 'legacy',
      extra: {'reasoningEfforts': {'low': 'low', 'high': 'high'}},
    );
    final kept = magpieModelSpec(model, metadata: {'owned_by': 'p'}, previous: withLevels);
    expect(kept.reasoningEfforts, {'low': 'low', 'high': 'high'});
  });

  test('keeps automatic and provider-specific metadata separate', () {
    const models = [DiscoveredModel(id: 'auto/x'), DiscoveredModel(id: 'p/x')];
    final grouped = groupMagpieModels(models, {
      'auto/x': {
        'owned_by': 'p',
        'native_endpoints': ['/v1/messages'],
        'supported_reasoning_levels': ['high'],
        'modalities': {'input': ['text', 'image']},
      },
      'p/x': {},
    });
    final automatic = grouped[MagpieRouteKind.anthropic]!.single;
    expect(automatic.id, 'auto/x');
    expect(automatic.input, ['text', 'image']);
    expect(automatic.reasoningEfforts, {'high': 'high'});
    expect(grouped[MagpieRouteKind.completions]!.single.id, 'p/x');
  });

  test('separates Auto Routing and supplier groups by protocol', () {
    const models = [
      DiscoveredModel(id: 'auto/glm-5.3-flash'),
      DiscoveredModel(id: 'volcengine/glm-5.3-flash'),
      DiscoveredModel(id: 'copilot/claude-opus-5-5'),
    ];
    final metadata = {
      'auto/glm-5.3-flash': {'owned_by': 'volcengine', 'native_endpoints': ['/v1/responses']},
      'volcengine/glm-5.3-flash': {
        'owned_by': 'volcengine',
        'native_endpoints': ['/v1/responses'],
        'display_name': 'GLM-5.3-Flash',
        'magpie_label': 'GLM-5.3-Flash · Volcengine Ark',
      },
      'copilot/claude-opus-5-5': {
        'owned_by': 'copilot',
        'native_endpoints': ['/v1/messages'],
        'display_name': 'Claude Opus 5.5',
        'magpie_label': 'Claude Opus 5.5 · GitHub Copilot',
      },
    };
    final grouped = groupMagpieModels(models, metadata);
    final routes = groupMagpieProviderRoutes(grouped, metadata);
    expect(routes.map((r) => r.route).toSet().length, 3);
    expect(routes.map((r) => r.owner), ['auto', 'copilot', 'volcengine']);
    expect(routes.map((r) => r.kind), [MagpieRouteKind.responses, MagpieRouteKind.anthropic, MagpieRouteKind.responses]);
    // 路由名带 M · 供应商显示名，模型名本身不再重复一遍供应商。
    expect(routes.map((r) => r.displayName), [
      'Auto Routing · Responses',
      'M · GitHub Copilot · Anthropic',
      'M · Volcengine Ark · Responses',
    ]);
    expect(routes[0].models.single.id, 'auto/glm-5.3-flash');
    expect(routes[0].models.single.name, startsWith('Auto Routing · '));
    expect(routes[1].models.single.id, 'copilot/claude-opus-5-5');
    expect(routes[1].models.single.name, 'Claude Opus 5.5');
    expect(routes[2].models.single.id, 'volcengine/glm-5.3-flash');
    expect(routes[2].models.single.name, 'GLM-5.3-Flash');
    for (final route in routes) {
      expect(providerRoutePattern.hasMatch(route.route), isTrue);
    }
  });

  test('keeps route ids unique across slugs protocols and reserved owners', () {
    const models = [
      DiscoveredModel(id: 'foo/a'),
      DiscoveredModel(id: 'foo-responses/b'),
      DiscoveredModel(id: 'foo-bar/c'),
      DiscoveredModel(id: 'foo bar/d'),
      DiscoveredModel(id: 'auto-routing/e'),
      DiscoveredModel(id: 'group/f'),
      DiscoveredModel(id: 'auto/g'),
    ];
    final metadata = {
      'foo/a': {'owned_by': 'foo', 'native_endpoints': ['/v1/responses']},
      'foo-responses/b': {'owned_by': 'foo-responses'},
      'foo-bar/c': {'owned_by': 'foo-bar'},
      'foo bar/d': {'owned_by': 'foo bar'},
      'auto-routing/e': {'owned_by': 'auto-routing'},
      'group/f': {'owned_by': 'group'},
      'auto/g': {'owned_by': 'volcengine'},
    };
    final routes = groupMagpieProviderRoutes(groupMagpieModels(models, metadata), metadata);
    expect(routes.length, 7);
    expect(routes.map((route) => route.route).toSet().length, routes.length);
    expect(routes.any((route) => route.route == 'magpie-group'), isFalse);
    expect(routes.singleWhere((route) => route.owner == 'auto').route, 'magpie-auto-routing');
    for (final route in routes) {
      expect(providerRoutePattern.hasMatch(route.route), isTrue);
    }
  });

  test('maps legacy supplier routes for migration', () {
    final route = MagpieProviderRoute('foo', MagpieRouteKind.responses, 'magpie-provider-foo-12345678-responses', 'Magpie · foo · Responses', const []);
    expect(magpieLegacySupplierRoute(route), 'magpie-foo-responses');
    expect(magpieLegacySupplierRoute(MagpieProviderRoute('foo', MagpieRouteKind.completions, 'x', 'x', const [])), 'magpie-foo');
  });

  test('accepts only the exact Magpie provider deep link', () {
    expect(isMagpieProviderLink(Uri.parse('dshgo://providers/magpie')), isTrue);
    expect(isMagpieProviderLink(Uri.parse('dshgo://providers/magpie?key=x')), isFalse);
    expect(isMagpieProviderLink(Uri.parse('https://providers/magpie')), isFalse);
    expect(isMagpieProviderLink(Uri.parse('dshgo://providers/other')), isFalse);
  });

  group('magpieImport', () {
    const discovered = [DiscoveredModel(id: 'model', contextWindow: 131072, maxTokens: 8192)];

    FakeProviderBackend backend(List<ProviderProfile> profiles) =>
        FakeProviderBackend(profiles: profiles)..discoverResult = discovered;

    ProviderProfile managed({
      String route = 'magpie',
      String? api = 'openai-completions',
      String? baseUrl = 'http://127.0.0.1:3425/v1',
      int? idle,
      List<ProviderModelSpec> models = const [],
    }) =>
        ProviderProfile(
          route: route,
          displayName: 'Magpie',
          api: api,
          baseUrl: baseUrl,
          apiKeyEnv: magpieGatewayKeyRef,
          models: models,
          streamIdleTimeoutMs: idle,
        );

    test('clean removes every magpie-managed route and writes fresh', () async {
      final b = backend([
        managed(
          idle: 999,
          models: const [
            ProviderModelSpec(
              id: 'model',
              maxTokens: 12345,
              extra: {'compat': {'supportsStrictMode': true}},
            ),
          ],
        ),
        const ProviderProfile(
          route: 'magpie-mine',
          displayName: 'my own',
          api: 'openai-completions',
          baseUrl: 'http://127.0.0.1:3425/v1',
          apiKeyEnv: 'MY_OWN_KEY',
        ),
        const ProviderProfile(
          route: 'my-gw',
          displayName: 'my gateway',
          api: 'openai-completions',
          baseUrl: 'https://gw.example.com/v1',
          apiKeyEnv: 'MY_GW_API_KEY',
        ),
      ]);
      final routes = await magpieImport(backend: b, discoveredModels: discovered, clean: true);
      expect(routes.fold<int>(0, (n, r) => n + r.models.length), 1);
      expect(b.profiles.map((p) => p.route).toSet(), {'magpie', 'magpie-mine', 'my-gw'});
      final route = b.profiles.firstWhere((p) => p.route == 'magpie');
      expect(route.streamIdleTimeoutMs, magpieStreamIdleTimeoutMs);
      expect(route.models.single.extra['compat'], isNull); // stale compat went away
      expect(route.models.single.maxTokens, isNot(12345)); // user cap reset
      expect(b.callNames, containsAllInOrder(['remove', 'create', 'storeKey']));
    });

    test('without clean the route keeps user picks, idle wait and compat', () async {
      final b = backend([
        managed(
          api: 'openai-responses',
          idle: 999,
          models: const [
            ProviderModelSpec(
              id: 'model',
              maxTokens: 12345,
              extra: {'compat': {'maxTokensField': 'max_completion_tokens'}},
            ),
          ],
        ),
      ]);
      await magpieImport(backend: b, discoveredModels: discovered);
      final route = b.profiles.single;
      expect(route.api, 'openai-responses'); // user pick survives
      expect(route.baseUrl, 'http://127.0.0.1:3425/v1');
      expect(route.streamIdleTimeoutMs, 999); // user idle wait survives
      final model = route.models.single;
      expect(model.maxTokens, 12345);
      expect(model.extra['compat'], {
        'maxTokensField': 'max_completion_tokens',
        'supportsStrictMode': true, // magpie's own switch on the resolved api
      });
      expect(b.callNames, containsAllInOrder(['update', 'storeKey']));
    });
  });
}
