import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/links/magpie_links.dart';
import 'package:dsh_app/state/magpie_models.dart';
import 'package:flutter_test/flutter_test.dart';

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
      metadata: {'supported_reasoning_levels': ['off', 'low', 'high']},
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
    expect(adaptiveClaudeModel('claude-sonnet-4-5'), isFalse);
    expect(adaptiveClaudeModel('claude-3-7-sonnet'), isFalse);
    expect(adaptiveThinkingModel('zcode/GLM-5.3-Flash'), isTrue);
    expect(adaptiveThinkingModel('deepseek-v4.1-flash'), isFalse);
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
      'supported_reasoning_levels': ['none', 'light', 'extra_high', 'ultra'],
    });
    expect(spec.input, ['text', 'image']);
    expect(spec.reasoningEfforts, {'off': null, 'low': 'low', 'xhigh': 'xhigh', 'max': 'max'});
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
      'volcengine/glm-5.3-flash': {'owned_by': 'volcengine', 'native_endpoints': ['/v1/responses']},
      'copilot/claude-opus-5-5': {'owned_by': 'copilot', 'native_endpoints': ['/v1/messages']},
    };
    final grouped = groupMagpieModels(models, metadata);
    final routes = groupMagpieProviderRoutes(grouped, metadata);
    expect(routes.map((r) => r.route).toSet().length, 3);
    expect(routes.map((r) => r.owner), ['auto', 'copilot', 'volcengine']);
    expect(routes.map((r) => r.kind), [MagpieRouteKind.responses, MagpieRouteKind.anthropic, MagpieRouteKind.responses]);
    expect(routes.map((r) => r.displayName), [
      'Auto Routing · Responses',
      'Magpie · copilot · Anthropic',
      'Magpie · volcengine · Responses',
    ]);
    expect(routes[0].models.single.id, 'auto/glm-5.3-flash');
    expect(routes[0].models.single.name, startsWith('Auto Routing · '));
    expect(routes[1].models.single.id, 'copilot/claude-opus-5-5');
    expect(routes[2].models.single.id, 'volcengine/glm-5.3-flash');
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
}
