import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/magpie_models.dart';
import '../state/models_state.dart';
import '../state/providers_state.dart';
import '../state/read_list_epoch.dart';
import '../state/settings_state.dart';
import 'app_links.dart';

const magpieProviderLinkHost = 'providers';
const magpieProviderLinkPath = '/magpie';

enum MagpieImportMode { api, provider }

bool isMagpieProviderLink(Uri uri) =>
    uri.scheme.toLowerCase() == appLinkScheme &&
    uri.host.toLowerCase() == magpieProviderLinkHost &&
    uri.path == magpieProviderLinkPath &&
    uri.userInfo.isEmpty &&
    !uri.hasPort &&
    !uri.hasQuery &&
    !uri.hasFragment;

/// Configure the local Magpie provider through DSH's own ProviderBackend.
/// The resulting profile and credential land in the active web profile's
/// cordis.patch.yml and credential store; no cross-app private file is read.
Future<int> configureMagpieProvider(WidgetRef ref, {MagpieImportMode mode = MagpieImportMode.api}) async {
  final backend = ref.read(providerBackendProvider);
  if (backend == null) throw ProviderFailure(appL10n.stateProviderOffline);
  if (!backend.isLocal) throw ProviderFailure(appL10n.magpieConnectUnavailable);
  ref.read(readListCredentialEpochProvider.notifier).advance();

  final discoveredModels = await backend.discover(
    baseUrl: magpieGatewayBaseUrl,
    api: ProviderApi.openaiCompletions,
    apiKey: magpieGatewayApiKey,
  );
  if (discoveredModels.isEmpty) throw ProviderFailure(appL10n.magpieConnectUnavailable);
  final metadata = await fetchMagpieModelMetadata();
  final settings = await backend.read();
  final profiles = settings?.profiles ?? const <ProviderProfile>[];
  final previous = <MagpieRouteKind, List<ProviderModelSpec>>{
    for (final kind in MagpieRouteKind.values)
      kind: [
        for (final profile in profiles)
          if (mode == MagpieImportMode.provider
              ? profile.route == 'magpie' || profile.route.startsWith('magpie-')
              : profile.route == kind.route) ...profile.models,
      ],
  };
  final grouped = groupMagpieModels(discoveredModels, metadata, existing: previous);
  List<ProviderModelSpec> rebased(MagpieProviderRoute route, ProviderProfile? profile) => [
    for (final spec in route.models)
      magpieModelSpec(
        discoveredModels.firstWhere((model) => model.id == spec.id),
        metadata: metadata[spec.id] ?? const <String, Object?>{},
        previous: profile?.models.where((old) => old.id == spec.id).firstOrNull,
        route: route.kind,
      ),
  ];
  final routes = mode == MagpieImportMode.provider
      ? groupMagpieProviderRoutes(grouped, metadata)
      : [
          for (final kind in MagpieRouteKind.values)
            MagpieProviderRoute('api', kind, kind.route, kind.displayName, grouped[kind]!),
        ];
  for (final route in routes) {
    final kind = route.kind;
    final existing = profiles.where((profile) => profile.route == route.route).firstOrNull;
    final latest = await backend.read();
    final latestExisting = latest?.profiles.where((profile) => profile.route == route.route).firstOrNull;
    if (route.models.isEmpty) {
      if (latestExisting != null) {
        await backend.remove(latestExisting.route, expectedRevision: latest?.revision ?? settings?.revision);
      }
      continue;
    }
    if (latestExisting == null) {
      if (existing != null) throw ProviderFailure(appL10n.magpieConnectConflict);
      await backend.create(
        ProviderProfile(
          route: route.route,
          displayName: route.displayName,
          api: kind.api.wire,
          baseUrl: kind.baseUrl,
          apiKeyEnv: magpieGatewayKeyRef,
          models: rebased(route, null),
          streamIdleTimeoutMs: magpieStreamIdleTimeoutMs,
        ),
        expectedRevision: latest?.revision ?? settings?.revision,
      );
    } else {
      await backend.update(
        latestExisting.route,
        displayName: route.displayName,
        api: kind.api,
        baseUrl: kind.baseUrl,
        apiKeyEnv: magpieGatewayKeyRef,
        models: rebased(route, latestExisting),
        streamIdleTimeoutMs: magpieStreamIdleTimeoutMs,
        expectedRevision: latest?.revision ?? settings?.revision,
      );
    }
  }
  if (mode == MagpieImportMode.provider) {
    const obsoleteGroupRoutes = {'magpie-group', 'magpie-group-responses', 'magpie-group-anthropic'};
    const obsoleteDisplayNames = {'Magpie Group', 'Magpie Group · Responses', 'Magpie Group · Anthropic'};
    final importedRoutes = routes.map((route) => route.route).toSet();
    for (final route in obsoleteGroupRoutes) {
      if (importedRoutes.contains(route)) continue;
      final latest = await backend.read();
      final existing = latest?.profiles.where((profile) => profile.route == route).firstOrNull;
      if (existing != null && obsoleteDisplayNames.contains(existing.displayName)) {
        await backend.remove(route, expectedRevision: latest?.revision ?? settings?.revision);
      }
    }
  }
  await backend.storeKey(magpieGatewayKeyRef, magpieGatewayApiKey);
  if (backend.isLocal) {
    for (final route in routes.where((route) => route.models.isNotEmpty)) {
      try {
        await ref.read(settingsProvider.notifier).saveProviderKey(route.route, magpieGatewayApiKey);
      } catch (_) {
        // The engine already has the key; only its self-heal copy is absent.
      }
    }
  }
  ref
    ..invalidate(customProvidersProvider)
    ..invalidate(modelCatalogProvider);
  return routes.fold<int>(0, (total, route) => total + route.models.length);
}

VoidCallback registerMagpieLinks(LinkRouter router, WidgetRef ref) => router.registerLinkHandler(
  '$magpieProviderLinkHost$magpieProviderLinkPath',
  (uri) async {
    if (!isMagpieProviderLink(uri)) return false;
    final context = router.context;
    if (context == null || !context.mounted) return false;
    final mode = await showDialog<MagpieImportMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(appL10n.magpieConnectTitle),
        content: Text(appL10n.magpieConnectBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(appL10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(MagpieImportMode.api), child: Text(appL10n.magpieConnectApi)),
          OutlinedButton(onPressed: () => Navigator.of(dialogContext).pop(MagpieImportMode.provider), child: Text(appL10n.magpieConnectProvider)),
        ],
      ),
    );
    if (mode == null) return true;
    if (!context.mounted) return true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnecting)));
    try {
      final count = await configureMagpieProvider(ref, mode: mode);
      messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnectSuccess(count))));
    } catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnectFailed(describeProviderError(error)))));
    }
    return true;
  },
);
