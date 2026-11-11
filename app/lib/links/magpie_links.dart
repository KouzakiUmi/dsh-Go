import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/magpie_models.dart';
import '../state/models_state.dart';
import '../state/providers_state.dart';
import '../state/read_list_epoch.dart';
import '../state/settings_state.dart';
import '../ui/common/app_dialog.dart';
import '../ui/theme/shapes.dart';
import 'app_links.dart';

const magpieProviderLinkHost = 'providers';
const magpieProviderLinkPath = '/magpie';

enum MagpieImportMode { api, provider }

/// The import the user picked in the dialog: which shape the routes take,
/// and whether every Magpie-managed profile is removed first. [clean] is
/// the recovery path for a state an earlier write left behind.
typedef MagpieImportRequest = ({MagpieImportMode mode, bool clean});

/// One step of a Magpie import. [total] 0 means the step count is not known
/// yet (the read phase); the bar shows indeterminate then. [label] is the
/// entry being worked on, already localized.
typedef MagpieImportProgress = ({String label, int done, int total});
typedef MagpieImportProgressCallback = void Function(MagpieImportProgress progress);

/// Routes an earlier supplier-group import wrote; the write pass retired
/// them, and the clean sweep removes them too.
const _magpieObsoleteGroupRoutes = {
  'magpie-group',
  'magpie-group-responses',
  'magpie-group-anthropic',
};

/// A provider profile one of magpie's imports manages: its route carries
/// the magpie prefix (or a supplier route's display name, `Magpie · …` on
/// imports before the `M · …` switch), and it still points at the local
/// gateway with the interop key reference — so a user's own route that
/// happens to start with "magpie" is left alone.
bool _magpieManaged(ProviderProfile profile) =>
    (profile.route.startsWith('magpie-provider-') ||
        (profile.route.startsWith('magpie-') &&
            ((profile.displayName ?? '').startsWith('Magpie · ') ||
                (profile.displayName ?? '').startsWith('M · '))) ||
        _magpieObsoleteGroupRoutes.contains(profile.route) ||
        MagpieRouteKind.values.any((kind) => kind.route == profile.route)) &&
    profile.apiKeyEnv == magpieGatewayKeyRef &&
    (profile.baseUrl == magpieGatewayBaseUrl || profile.baseUrl == 'http://127.0.0.1:3425');

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
/// [onProgress] reports each route as it is written or removed so a caller
/// can hold a dialog open for the whole import. With [clean] every profile
/// magpie manages is removed before the write, clearing whatever an earlier
/// import left — user picks and edits on those routes go with them.
Future<int> configureMagpieProvider(
  WidgetRef ref, {
  MagpieImportMode mode = MagpieImportMode.api,
  bool clean = false,
  MagpieImportProgressCallback? onProgress,
}) async {
  final backend = ref.read(providerBackendProvider);
  if (backend == null) throw ProviderFailure(appL10n.stateProviderOffline);
  if (!backend.isLocal) throw ProviderFailure(appL10n.magpieConnectUnavailable);
  ref.read(readListCredentialEpochProvider.notifier).advance();

  onProgress?.call((label: appL10n.magpieProgressDiscover, done: 0, total: 0));
  final discoveredModels = await backend.discover(
    baseUrl: magpieGatewayBaseUrl,
    api: ProviderApi.openaiCompletions,
    apiKey: magpieGatewayApiKey,
  );
  if (discoveredModels.isEmpty) throw ProviderFailure(appL10n.magpieConnectUnavailable);
  onProgress?.call((label: appL10n.magpieProgressReadMeta, done: 0, total: 0));
  final metadata = await fetchMagpieModelMetadata();
  final routes = await magpieImport(
    backend: backend,
    discoveredModels: discoveredModels,
    metadata: metadata,
    mode: mode,
    clean: clean,
    onProgress: onProgress,
  );
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

/// Write the magpie routes, removals and credential through [backend].
/// This is the whole import once the model list and detail are known; the
/// gateway reads and profile-copy key heal stay in
/// [configureMagpieProvider], so a test can call this with a fake backend
/// alone. Returns the routes it resolved; each carries the models written
/// (or an empty list when its profile was removed).
Future<List<MagpieProviderRoute>> magpieImport({
  required ProviderBackend backend,
  required List<DiscoveredModel> discoveredModels,
  Map<String, Map<String, Object?>> metadata = const {},
  MagpieImportMode mode = MagpieImportMode.api,
  bool clean = false,
  MagpieImportProgressCallback? onProgress,
}) async {
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
  List<ProviderModelSpec> rebased(MagpieProviderRoute route, ProviderProfile? profile, String api) => [
    for (final spec in route.models)
      magpieModelSpec(
        discoveredModels.firstWhere((model) => model.id == spec.id),
        metadata: metadata[spec.id] ?? const <String, Object?>{},
        previous: profile?.models.where((old) => old.id == spec.id).firstOrNull,
        route: route.kind,
        api: api,
        previousApi: profile?.api,
      ),
  ];
  final routes = mode == MagpieImportMode.provider
      ? groupMagpieProviderRoutes(grouped, metadata)
      : [
          for (final kind in MagpieRouteKind.values)
            MagpieProviderRoute('api', kind, kind.route, kind.displayName, grouped[kind]!),
        ];
  var step = 0;
  final routeCount = routes.length;
  // Each removal pass counts its candidates up front so the bar moves
  // through a fixed total; adding to total inside the loop would keep
  // done/total constant and freeze the bar.
  var total = routeCount + 1; // routes + credential save
  void advance(String label) {
    step += 1;
    onProgress?.call((label: label, done: step, total: total));
  }

  if (clean) {
    // Drop every profile magpie manages before writing: what an earlier
    // import left — stale routes, bad flags — goes with them. Nothing is
    // carried over, so the write pass creates each route from scratch.
    final latest = await backend.read();
    final managed = <ProviderProfile>[
      for (final profile in latest?.profiles ?? const <ProviderProfile>[])
        if (_magpieManaged(profile)) profile,
    ];
    total += managed.length;
    for (final profile in managed) {
      final current = await backend.read();
      if (current?.profiles.where((item) => item.route == profile.route).firstOrNull == null) continue;
      advance(appL10n.magpieProgressRemoveRoute(profile.displayName ?? profile.route));
      await backend.remove(profile.route, expectedRevision: current?.revision ?? latest?.revision);
    }
  }

  for (final route in routes) {
    final kind = route.kind;
    advance(
      route.models.isEmpty
          ? appL10n.magpieProgressRemoveRoute(route.displayName)
          : appL10n.magpieProgressWriteRoute(route.displayName, route.models.length),
    );
    final existing = profiles.where((profile) => profile.route == route.route).firstOrNull;
    final latest = await backend.read();
    final latestExisting = latest?.profiles.where((profile) => profile.route == route.route).firstOrNull;
    final latestLegacy = !clean && mode == MagpieImportMode.provider
        ? latest?.profiles.where((profile) => profile.route == magpieLegacySupplierRoute(route) && profile.route != route.route).firstOrNull
        : null;
    final previousProfile = clean ? null : (latestExisting ?? latestLegacy);
    // The protocol the user picked for the route stays when the gateway
    // speaks it (`dshAPI`); a legacy supplier route or a foreign value falls
    // back to the kind's own. The base URL follows the resolved api.
    final resolvedApi = magpieApiFor(kind, latestExisting?.api);
    if (route.models.isEmpty) {
      if (latestExisting != null) {
        await backend.remove(latestExisting.route, expectedRevision: latest?.revision ?? settings?.revision);
      }
      continue;
    }
    if (latestExisting == null) {
      // A route that appeared in the first read but is gone now changed
      // under us — unless the clean sweep just removed it on purpose.
      if (!clean && existing != null) throw ProviderFailure(appL10n.magpieConnectConflict);
      await backend.create(
        ProviderProfile(
          route: route.route,
          displayName: route.displayName,
          api: resolvedApi.wire,
          baseUrl: magpieBaseUrlFor(resolvedApi),
          apiKeyEnv: magpieGatewayKeyRef,
          models: rebased(route, null, resolvedApi.wire),
          streamIdleTimeoutMs: magpieStreamIdleTimeoutMs,
        ),
        expectedRevision: latest?.revision ?? settings?.revision,
      );
    } else {
      await backend.update(
        latestExisting.route,
        displayName: route.displayName,
        api: resolvedApi,
        baseUrl: magpieBaseUrlFor(resolvedApi),
        apiKeyEnv: magpieGatewayKeyRef,
        models: rebased(route, previousProfile, resolvedApi.wire),
        // The wait already on the route — the user's, or the one magpie
        // wrote — stays (`dshIdleKey`).
        streamIdleTimeoutMs: latestExisting.streamIdleTimeoutMs ?? magpieStreamIdleTimeoutMs,
        expectedRevision: latest?.revision ?? settings?.revision,
      );
    }
  }
  if (mode == MagpieImportMode.provider) {
    final desiredRoutes = routes.map((route) => route.route).toSet();
    final apiRoutes = MagpieRouteKind.values.map((kind) => kind.route).toSet();
    final latest = await backend.read();
    final orphans = <ProviderProfile>[
      for (final profile in latest?.profiles ?? const <ProviderProfile>[])
        if (!desiredRoutes.contains(profile.route) &&
            !apiRoutes.contains(profile.route) &&
            _magpieManaged(profile))
          profile,
    ];
    total += orphans.length;
    for (final profile in orphans) {
      final current = await backend.read();
      final currentProfile = current?.profiles.where((item) => item.route == profile.route).firstOrNull;
      if (currentProfile != null) {
        advance(appL10n.magpieProgressRemoveRoute(profile.displayName ?? profile.route));
        await backend.remove(profile.route, expectedRevision: current?.revision ?? latest?.revision);
      }
    }
  }
  if (mode == MagpieImportMode.provider) {
    const obsoleteGroupRoutes = {'magpie-group', 'magpie-group-responses', 'magpie-group-anthropic'};
    const obsoleteDisplayNames = {'Magpie Group', 'Magpie Group · Responses', 'Magpie Group · Anthropic'};
    final importedRoutes = routes.map((route) => route.route).toSet();
    final snapshot = await backend.read();
    final obsolete = <ProviderProfile>[
      for (final route in obsoleteGroupRoutes)
        if (!importedRoutes.contains(route))
          for (final profile in snapshot?.profiles ?? const <ProviderProfile>[])
            if (profile.route == route && obsoleteDisplayNames.contains(profile.displayName)) profile,
    ];
    total += obsolete.length;
    for (final existing in obsolete) {
      final latest = await backend.read();
      if (latest?.profiles.where((item) => item.route == existing.route).firstOrNull == null) continue;
      advance(appL10n.magpieProgressRemoveRoute(existing.displayName ?? existing.route));
      await backend.remove(existing.route, expectedRevision: latest?.revision ?? settings?.revision);
    }
  }
  advance(appL10n.magpieProgressSaveKey);
  await backend.storeKey(magpieGatewayKeyRef, magpieGatewayApiKey);
  return routes;
}

VoidCallback registerMagpieLinks(LinkRouter router, WidgetRef ref) => router.registerLinkHandler(
  '$magpieProviderLinkHost$magpieProviderLinkPath',
  (uri) async {
    if (!isMagpieProviderLink(uri)) return false;
    final context = router.context;
    if (context == null || !context.mounted) return false;
    final request = await showDialog<MagpieImportRequest>(
      context: context,
      builder: (_) => const _MagpieConnectDialog(),
    );
    if (request == null) return true;
    if (!context.mounted) return true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final outcome = await showAppDialog<MagpieImportOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MagpieImportDialog(request: request),
    );
    switch (outcome) {
      case MagpieImportSuccess(:final count):
        messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnectSuccess(count))));
      case MagpieImportFailure(:final error):
        messenger?.showSnackBar(SnackBar(content: Text(appL10n.magpieConnectFailed(describeProviderError(error)))));
      case null:
        break;
    }
    return true;
  },
);

/// Result of one import run: the number of models on success, the thrown
/// error otherwise. Drives the dialog's outcome line and the toast after it.
sealed class MagpieImportOutcome {
  const MagpieImportOutcome();
}

final class MagpieImportSuccess extends MagpieImportOutcome {
  const MagpieImportSuccess(this.count);
  final int count;
}

final class MagpieImportFailure extends MagpieImportOutcome {
  const MagpieImportFailure(this.error);
  final Object error;
}

/// The connect dialog: which shape the routes take, and whether to remove
/// every Magpie-managed profile first. Both mode buttons take the dialog
/// with the [MagpieImportRequest] the checkboxes currently spell out.
class _MagpieConnectDialog extends StatefulWidget {
  const _MagpieConnectDialog();

  @override
  State<_MagpieConnectDialog> createState() => _MagpieConnectDialogState();
}

class _MagpieConnectDialogState extends State<_MagpieConnectDialog> {
  bool _clean = false;

  @override
  Widget build(BuildContext context) {
    void done(MagpieImportMode mode) => Navigator.of(context).pop((mode: mode, clean: _clean));
    return AlertDialog(
      title: Text(appL10n.magpieConnectTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appL10n.magpieConnectBody),
          CheckboxListTile(
            value: _clean,
            onChanged: (value) => setState(() => _clean = value ?? false),
            title: Text(appL10n.magpieConnectClean),
            subtitle: Text(appL10n.magpieConnectCleanHint),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(appL10n.commonCancel)),
        FilledButton(onPressed: () => done(MagpieImportMode.api), child: Text(appL10n.magpieConnectApi)),
        OutlinedButton(onPressed: () => done(MagpieImportMode.provider), child: Text(appL10n.magpieConnectProvider)),
      ],
    );
  }
}

/// Non-dismissible dialog that runs one Magpie import and reports each
/// route as it is written or removed. The bar is indeterminate while the
/// gateway is being read, then counts route by route.
class _MagpieImportDialog extends ConsumerStatefulWidget {
  const _MagpieImportDialog({required this.request});

  final MagpieImportRequest request;

  @override
  ConsumerState<_MagpieImportDialog> createState() => _MagpieImportDialogState();
}

class _MagpieImportDialogState extends ConsumerState<_MagpieImportDialog> {
  final _progress = ValueNotifier<MagpieImportProgress>(
    (label: appL10n.magpieProgressDiscover, done: 0, total: 0),
  );

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    MagpieImportOutcome outcome;
    try {
      outcome = MagpieImportSuccess(
        await configureMagpieProvider(
          ref,
          mode: widget.request.mode,
          clean: widget.request.clean,
          onProgress: (progress) => _progress.value = progress,
        ),
      );
    } catch (error) {
      outcome = MagpieImportFailure(error);
    }
    if (mounted) Navigator.of(context).pop(outcome);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(appL10n.magpieConnectTitle),
        content: ValueListenableBuilder<MagpieImportProgress>(
          valueListenable: _progress,
          builder: (context, progress, _) {
            final value = progress.total > 0 ? progress.done / progress.total : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: AppShape.radiusXs,
                  child: LinearProgressIndicator(value: value, minHeight: 4),
                ),
                const SizedBox(height: 12),
                Text(progress.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (progress.total > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    appL10n.magpieProgressSteps(progress.done, progress.total),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
