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

  test('replaces auto aliases with owned provider ids and deduplicates', () {
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
    expect(grouped[MagpieRouteKind.completions]!.map((m) => m.id), ['volcengine/glm-5.3-flash']);
    expect(grouped[MagpieRouteKind.anthropic]!.single.id, 'copilot/claude-opus-5-5');
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

  test('merges alias metadata when canonical metadata is sparse', () {
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
    final model = grouped[MagpieRouteKind.anthropic]!.single;
    expect(model.input, ['text', 'image']);
    expect(model.reasoningEfforts, {'high': 'high'});
  });

  test('groups models by provider inside Magpie Group protocol routes', () {
    const models = [
      DiscoveredModel(id: 'auto/glm-5.3-flash'),
      DiscoveredModel(id: 'auto/claude-opus-5-5'),
    ];
    final grouped = groupMagpieModels(models, {
      'auto/glm-5.3-flash': {'owned_by': 'volcengine', 'native_endpoints': ['/v1/responses']},
      'auto/claude-opus-5-5': {'owned_by': 'copilot', 'native_endpoints': ['/v1/messages']},
    });
    final routes = groupMagpieProviderRoutes(grouped, {
      'auto/glm-5.3-flash': {'owned_by': 'volcengine', 'native_endpoints': ['/v1/responses']},
      'auto/claude-opus-5-5': {'owned_by': 'copilot', 'native_endpoints': ['/v1/messages']},
    });
    expect(routes.map((r) => r.route), ['magpie-group', 'magpie-group-responses', 'magpie-group-anthropic']);
    expect(routes.map((r) => r.displayName), ['Magpie Group', 'Magpie Group · Responses', 'Magpie Group · Anthropic']);
    expect(routes[1].models.single.name, startsWith('volcengine · '));
    expect(routes[2].models.single.name, startsWith('copilot · '));
  });

  test('accepts only the exact Magpie provider deep link', () {
    expect(isMagpieProviderLink(Uri.parse('dshgo://providers/magpie')), isTrue);
    expect(isMagpieProviderLink(Uri.parse('dshgo://providers/magpie?key=x')), isFalse);
    expect(isMagpieProviderLink(Uri.parse('https://providers/magpie')), isFalse);
    expect(isMagpieProviderLink(Uri.parse('dshgo://providers/other')), isFalse);
  });
}
