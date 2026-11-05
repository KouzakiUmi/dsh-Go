import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';

const magpieGatewayBaseUrl = 'http://127.0.0.1:3425/v1';
const magpieGatewayKeyRef = 'MAGPIE_GATEWAY_KEY';
const magpieGatewayApiKey = 'magpie';
const magpieStreamIdleTimeoutMs = 600000;

class MagpieModelDiscoveryException implements Exception {
  const MagpieModelDiscoveryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read Magpie's richer model metadata after DSH's own discovery has proved
/// that the engine can reach the gateway. No provider credential is involved:
/// Magpie's local gateway key is intentionally a fixed interoperability value.
Future<Map<String, Map<String, Object?>>> fetchMagpieModelMetadata() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(Uri.parse('$magpieGatewayBaseUrl/models'));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $magpieGatewayApiKey');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      throw MagpieModelDiscoveryException('Magpie model listing answered ${response.statusCode}');
    }
    final buffer = StringBuffer();
    await for (final chunk in response.transform(utf8.decoder).timeout(const Duration(seconds: 15))) {
      buffer.write(chunk);
      if (buffer.length > 4 * 1024 * 1024) {
        throw const MagpieModelDiscoveryException('Magpie model listing is too large');
      }
    }
    final text = buffer.toString();
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['data'] is! List) {
      throw const MagpieModelDiscoveryException('Magpie model listing has no data array');
    }
    return {
      for (final raw in decoded['data'])
        if (raw is Map && raw['id'] is String && (raw['id'] as String).isNotEmpty)
          raw['id'] as String: raw.cast<String, Object?>(),
    };
  } on MagpieModelDiscoveryException {
    rethrow;
  } on Exception catch (error) {
    throw MagpieModelDiscoveryException('Could not read Magpie model metadata: $error');
  } finally {
    client.close();
  }
}

int? _cappedMaxTokens(DiscoveredModel model) {
  final output = model.maxTokens;
  if (output == null) return null;
  final context = model.contextWindow;
  if (context == null || context <= 0) return output;
  final room = math.max(context ~/ 4, context ~/ 2 - 65536);
  return math.min(output, math.max(1, room));
}

/// The dsh level key a native effort name stands for. A name that is not a
/// dsh level is the upstream vendor's own spelling: it offers the level it is
/// closest to and is sent back to the gateway as it came (the gateway knows
/// what its provider takes), as the desktop importer does with `modelEffort`.
const _reasoningLevelAliases = <String, String>{
  'none': 'off',
  'off': 'off',
  'minimal': 'minimal',
  'light': 'low',
  'low': 'low',
  'medium': 'medium',
  'high': 'high',
  'xhigh': 'xhigh',
  'extra_high': 'xhigh',
  'ultra': 'max',
  'max': 'max',
};

/// One raw level entry's native effort name: `supported_reasoning_levels`
/// lists `{effort, summary}` objects (OpenAI's `/models` shape), while
/// `reasoning_levels` lists bare names.
String? _rawEffortName(Object? raw) {
  if (raw is String) return raw;
  if (raw is Map && raw['effort'] is String) return raw['effort'] as String;
  return null;
}

/// The `reasoningEfforts` value a model's raw levels yield: each offered dsh
/// level to the native effort name the gateway sends for it, in the schema's
/// level order (the desktop importer's `dshModelLevels` ordering). An
/// explicit empty or `off`-only level list becomes `false` — llm-pi-ai
/// rejects a map with no level beyond `off`, and `false` is its spelling for
/// a model that does not think. Null when the metadata says nothing (the
/// caller then keeps what was there).
Object? _reasoningEfforts(Map<String, Object?> metadata) {
  final raw = metadata['supported_reasoning_levels'] ?? metadata['reasoning_levels'];
  if (raw is! List) return null;
  final names = <String, String>{};
  for (final entry in raw) {
    final name = _rawEffortName(entry);
    if (name == null || name.isEmpty) continue;
    names.putIfAbsent(name.toLowerCase(), () => name);
  }
  final efforts = <String, Object?>{};
  for (final level in piAiThinkingLevels) {
    final name = names.entries
        .where((entry) => _reasoningLevelAliases[entry.key] == level)
        .map((entry) => entry.value)
        .firstOrNull;
    if (name == null) continue;
    efforts[level] = level == 'off' ? null : name;
  }
  return efforts.keys.any((level) => level != 'off') ? efforts : false;
}

/// A Claude 4.6+ (or GLM-5.2/5.3, the `AdaptiveWithEffort` half) asks for
/// thinking adaptively, never with a budget: on an `anthropic-messages`
/// route such a model needs `compat.forceAdaptiveThinking` (`dshKindConfig`
/// upstream). The pattern is the gateway's own `claudeVersion`, including
/// its version-first spelling (`claude-5-sonnet`), plus `glmOutputEffort`.
final _claudeVersionPattern = RegExp(
  r'(?:^|[^a-z0-9])(?:claude-)?(?:opus|sonnet|haiku|fable|mythos)-(\d{1,2})(?:[-.](\d{1,2}))?(?:[^0-9]|$)'
  r'|claude-(\d+)(?:[-.](\d))?-(?:opus|sonnet|haiku)',
  caseSensitive: false,
);

bool adaptiveClaudeModel(String id) {
  final match = _claudeVersionPattern.firstMatch(id);
  if (match == null) return false;
  final major = int.parse(match.group(1) ?? match.group(3)!);
  final minor = int.tryParse(match.group(2) ?? match.group(4) ?? '0') ?? 0;
  return major > 4 || major == 4 && minor >= 6;
}

bool adaptiveThinkingModel(String id) =>
    adaptiveClaudeModel(id) || RegExp(r'glm-5\.[23](?:$|[-.:/\[])', caseSensitive: false).hasMatch(id);

/// Build one model while preserving a previous entry's compat switches and
/// user-set output cap. The previous compat travels only when the route
/// still resolves to the same wire protocol (`dshKeepCompat`: a protocol
/// change starts the model without it); each switch magpie sets itself is
/// put as magpie has it now. [api] is the api the route resolves to when it
/// is not the kind's own — a user-picked protocol stays, and compat flags
/// follow it, not the kind's name. [previousApi] is the wire value the
/// previous entry sat under; null preserves compat (the caller could not
/// tell). Magpie's current reasoning levels replace older ones.
ProviderModelSpec magpieModelSpec(
  DiscoveredModel model, {
  Map<String, Object?> metadata = const {},
  ProviderModelSpec? previous,
  MagpieRouteKind route = MagpieRouteKind.completions,
  String? api,
  String? previousApi,
}) {
  final resolvedApi = api ?? route.api.wire;
  final extra = {...?previous?.extra};
  final previousCompat = extra['compat'] is Map ? (extra['compat'] as Map).cast<String, Object?>() : null;
  // Rebuilt from scratch: a switch the previous entry had only travels when
  // the protocol still matches, so a stale map must not ride along in extra.
  extra.remove('compat');
  final compat = <String, Object?>{};
  if (previousApi == null || previousApi == resolvedApi) {
    if (previousCompat != null) compat.addAll(previousCompat);
  }
  if (resolvedApi == ProviderApi.openaiResponses.wire) compat['supportsStrictMode'] = true;
  if (resolvedApi == ProviderApi.anthropicMessages.wire && adaptiveThinkingModel(model.id)) {
    compat['forceAdaptiveThinking'] = true;
  }
  if (compat.isNotEmpty) extra['compat'] = compat;
  // Magpie's current levels replace what the entry had; a metadata block
  // that names no level field leaves it alone.
  final efforts = _reasoningEfforts(metadata);
  if (efforts != null) extra['reasoningEfforts'] = efforts;
  final rawModalities = metadata['modalities'];
  final metadataInput = rawModalities is Map && rawModalities['input'] is List
      ? (rawModalities['input'] as List).whereType<String>().toList(growable: false)
      : null;
  final input = (model.inputModalities ?? metadataInput ?? previous?.input)
      ?.where((kind) => kind == 'text' || kind == 'image')
      .toList(growable: false);
  final owner = metadata['owned_by'] as String?;
  final rawName = (metadata['display_name'] as String?) ?? model.name ?? previous?.name ?? model.id;
  final displayOwner = isAutoRoutingModelId(model.id) ? 'Auto Routing' : owner;
  final displayName = displayOwner != null && displayOwner.isNotEmpty ? '$displayOwner · $rawName' : rawName;
  // An absent or non-positive window writes nothing (`omitempty` upstream).
  final contextWindow = model.contextWindow ?? previous?.contextWindow;
  final spec = ProviderModelSpec(
    id: model.id,
    name: displayName,
    contextWindow: contextWindow != null && contextWindow > 0 ? contextWindow : null,
    maxTokens: previous?.maxTokens ?? _cappedMaxTokens(model),
    input: input,
    extra: extra,
  );
  return spec;
}

List<ProviderModelSpec> mergeMagpieModels(
  List<DiscoveredModel> discovered,
  Map<String, Map<String, Object?>> metadata, {
  List<ProviderModelSpec> existing = const [],
  MagpieRouteKind route = MagpieRouteKind.completions,
}) {
  final previous = {for (final model in existing) model.id: model};
  return [
    for (final model in discovered)
      magpieModelSpec(
        model,
        metadata: metadata[model.id] ?? const {},
        previous: previous[model.id],
        route: route,
      ),
  ];
}

enum MagpieRouteKind {
  completions('magpie', 'Magpie', ProviderApi.openaiCompletions, magpieGatewayBaseUrl),
  responses('magpie-responses', 'Magpie · Responses', ProviderApi.openaiResponses, magpieGatewayBaseUrl),
  anthropic('magpie-anthropic', 'Magpie · Anthropic', ProviderApi.anthropicMessages, 'http://127.0.0.1:3425');

  const MagpieRouteKind(this.route, this.displayName, this.api, this.baseUrl);
  final String route;
  final String displayName;
  final ProviderApi api;
  final String baseUrl;
}

/// The api a Magpie route resolves to (`dshAPI`): the wire protocol the
/// route stands on now stays when it is one the gateway speaks — a user who
/// switched the route's protocol in DSH keeps it — and the kind's own
/// otherwise (unset, or one the gateway has no endpoint for).
ProviderApi magpieApiFor(MagpieRouteKind kind, String? current) =>
    ProviderApi.fromWire(current) ?? kind.api;

/// The gateway address a route on [api] serves under (`dshBaseURL`):
/// Anthropic's SDK adds `/v1/messages` itself, so Messages is at the
/// gateway's root; OpenAI's SDKs add only the endpoint path, so theirs is
/// `/v1`.
String magpieBaseUrlFor(ProviderApi api) =>
    api == ProviderApi.anthropicMessages ? 'http://127.0.0.1:3425' : magpieGatewayBaseUrl;

MagpieRouteKind magpieRouteFor(Map<String, Object?> metadata) {
  final endpoints = metadata['native_endpoints'];
  if (endpoints is List && endpoints.contains('/v1/responses')) return MagpieRouteKind.responses;
  if (endpoints is List && endpoints.contains('/v1/messages')) return MagpieRouteKind.anthropic;
  return MagpieRouteKind.completions;
}

bool isAutoRoutingModelId(String id) => id.startsWith('auto/');

String magpieProviderModelId(DiscoveredModel model, Map<String, Map<String, Object?>> metadata) => model.id;

String magpieOwnerOf(DiscoveredModel model, Map<String, Map<String, Object?>> metadata) {
  if (isAutoRoutingModelId(model.id)) return 'auto';
  final owner = metadata[model.id]?['owned_by'];
  if (owner is String && owner.isNotEmpty && owner != 'auto') return owner;
  final separator = model.id.indexOf('/');
  return separator > 0 ? model.id.substring(0, separator) : 'other';
}

class MagpieProviderRoute {
  const MagpieProviderRoute(this.owner, this.kind, this.route, this.displayName, this.models);
  final String owner;
  final MagpieRouteKind kind;
  final String route;
  final String displayName;
  final List<ProviderModelSpec> models;
}

String magpieProviderOwnerSlug(String owner) {
  final value = owner.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return value.isEmpty ? 'other' : value;
}

String magpieLegacySupplierRoute(MagpieProviderRoute route) {
  final suffix = switch (route.kind) {
    MagpieRouteKind.completions => '',
    MagpieRouteKind.responses => '-responses',
    MagpieRouteKind.anthropic => '-anthropic',
  };
  return 'magpie-${magpieProviderOwnerSlug(route.owner)}$suffix';
}

List<MagpieProviderRoute> groupMagpieProviderRoutes(
  Map<MagpieRouteKind, List<ProviderModelSpec>> grouped,
  Map<String, Map<String, Object?>> metadata,
) {
  final buckets = <String, List<ProviderModelSpec>>{};
  for (final kind in MagpieRouteKind.values) {
    for (final model in grouped[kind]!) {
      final owner = isAutoRoutingModelId(model.id)
          ? 'auto'
          : (metadata[model.id]?['owned_by'] as String?)?.trim().isNotEmpty == true
              ? (metadata[model.id]!['owned_by'] as String).trim()
              : model.id.contains('/')
                  ? model.id.substring(0, model.id.indexOf('/'))
                  : 'other';
      buckets.putIfAbsent('$owner\u0000${kind.name}', () => []).add(model);
    }
  }
  final owners = buckets.keys.map((key) => key.split('\u0000').first).toSet().toList()
    ..sort((a, b) => a == 'auto' ? -1 : b == 'auto' ? 1 : a.compareTo(b));
  String slug(String owner) => magpieProviderOwnerSlug(owner);
  String label(MagpieRouteKind kind) => switch (kind) {
    MagpieRouteKind.completions => '',
    MagpieRouteKind.responses => ' · Responses',
    MagpieRouteKind.anthropic => ' · Anthropic',
  };
  String ownerHash(String owner) {
    var hash = 0x811c9dc5;
    for (final unit in owner.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
  String autoRoute(MagpieRouteKind kind) => switch (kind) {
    MagpieRouteKind.completions => 'magpie-auto-routing',
    MagpieRouteKind.responses => 'magpie-auto-routing-responses',
    MagpieRouteKind.anthropic => 'magpie-auto-routing-anthropic',
  };
  final routes = [
    for (final owner in owners)
      for (final kind in MagpieRouteKind.values)
        if (buckets['$owner\u0000${kind.name}']?.isNotEmpty == true)
          MagpieProviderRoute(
            owner,
            kind,
            owner == 'auto'
                ? autoRoute(kind)
                : 'magpie-provider-${slug(owner)}-${ownerHash(owner)}-${kind.name}',
            '${owner == 'auto' ? 'Auto Routing' : 'Magpie · $owner'}${label(kind)}',
            [...buckets['$owner\u0000${kind.name}']!]..sort((a, b) => a.id.compareTo(b.id)),
          ),
  ];
  final seen = <String>{};
  for (final route in routes) {
    if (!seen.add(route.route)) {
      throw MagpieModelDiscoveryException('Provider route identity collision for ${route.owner}');
    }
  }
  return routes;
}

Map<MagpieRouteKind, List<ProviderModelSpec>> groupMagpieModels(
  List<DiscoveredModel> discovered,
  Map<String, Map<String, Object?>> metadata, {
  Map<MagpieRouteKind, List<ProviderModelSpec>> existing = const {},
}) {
  final grouped = <MagpieRouteKind, List<ProviderModelSpec>>{
    for (final kind in MagpieRouteKind.values) kind: [],
  };
  final unique = <String, DiscoveredModel>{};
  final rawById = <String, Map<String, Object?>>{};
  for (final original in discovered) {
    final id = original.id;
    unique[id] = DiscoveredModel(
      id: id,
      name: original.name,
      contextWindow: original.contextWindow,
      maxTokens: original.maxTokens,
      inputModalities: original.inputModalities,
    );
    rawById[id] = {
      ...?rawById[id],
      ...?metadata[original.id],
      ...?metadata[id],
    };
  }
  for (final model in unique.values) {
    final raw = rawById[model.id] ?? const <String, Object?>{};
    final kind = magpieRouteFor(raw);
    final previous = <String, ProviderModelSpec>{
      for (final old in existing[kind] ?? const <ProviderModelSpec>[]) old.id: old,
    };
    grouped[kind]!.add(
      magpieModelSpec(model, metadata: raw, previous: previous[model.id], route: kind, api: kind.api.wire),
    );
  }
  return grouped;
}
