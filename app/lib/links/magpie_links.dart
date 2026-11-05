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
Future<int> configureMagpieProvider(WidgetRef ref) async {
  final backend = ref.read(providerBackendProvider);
  if (backend == null) throw ProviderFailure(appL10n.stateProviderOffline);
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
          if (profile.route == kind.route) ...profile.models,
      ],
  };
  final grouped = groupMagpieModels(discoveredModels, metadata, existing: previous);
  for (final kind in MagpieRouteKind.values) {
    final models = grouped[kind]!;
    final existing = profiles.where((profile) => profile.route == kind.route).firstOrNull;
    if (models.isEmpty) {
      if (existing != null) {
        final revision = (await backend.read())?.revision ?? settings?.revision;
        await backend.remove(existing.route, expectedRevision: revision);
      }
      continue;
    }
    if (existing == null) {
      await backend.create(
        ProviderProfile(
          route: kind.route,
          displayName: kind.displayName,
          api: kind.api.wire,
          baseUrl: kind.baseUrl,
          apiKeyEnv: magpieGatewayKeyRef,
          models: models,
          streamIdleTimeoutMs: magpieStreamIdleTimeoutMs,
        ),
      );
    } else {
      final revision = (await backend.read())?.revision ?? settings?.revision;
      await backend.update(
        existing.route,
        displayName: kind.displayName,
        api: kind.api,
        baseUrl: kind.baseUrl,
        apiKeyEnv: magpieGatewayKeyRef,
        models: models,
        streamIdleTimeoutMs: existing.streamIdleTimeoutMs ?? magpieStreamIdleTimeoutMs,
        expectedRevision: revision,
      );
    }
  }
  await backend.storeKey(magpieGatewayKeyRef, magpieGatewayApiKey);
  if (backend.isLocal) {
    for (final kind in MagpieRouteKind.values) {
      try {
        await ref.read(settingsProvider.notifier).saveProviderKey(kind.route, magpieGatewayApiKey);
      } catch (_) {
        // The engine already has the key; only its self-heal copy is absent.
      }
    }
  }
  ref
    ..invalidate(customProvidersProvider)
    ..invalidate(modelCatalogProvider);
  var checked = 0;
  for (final kind in MagpieRouteKind.values) {
    if (grouped[kind]!.isEmpty) continue;
    checked += (await backend.discover(provider: kind.route, baseUrl: kind.baseUrl, api: kind.api)).length;
  }
  return checked;
}

VoidCallback registerMagpieLinks(LinkRouter router, WidgetRef ref) => router.registerLinkHandler(
  '$magpieProviderLinkHost$magpieProviderLinkPath',
  (uri) async {
    if (!isMagpieProviderLink(uri)) return false;
    final context = router.context;
    if (context == null || !context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(appL10n.magpieConnectTitle),
        content: Text(appL10n.magpieConnectBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(appL10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(appL10n.commonConfirm)),
        ],
      ),
    );
    if (confirmed != true) return true;
    if (!context.mounted) return true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnecting)));
    try {
      final count = await configureMagpieProvider(ref);
      messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnectSuccess(count))));
    } catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnectFailed(describeProviderError(error)))));
    }
    return true;
  },
);
