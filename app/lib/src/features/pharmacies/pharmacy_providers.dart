import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import 'pharmacy_search.dart';

/// Opens links in other apps (tests override it with a fake).
final urlOpenerProvider = Provider<UrlOpener>(
  (ref) => const UrlLauncherOpener(),
);

/// The pharmacy search of this platform and build region.
final pharmacySearchProvider = Provider<PharmacySearch>(
  (ref) => PharmacySearch(
    opener: ref.watch(urlOpenerProvider),
    platform: defaultTargetPlatform,
    region: ref.watch(apiConfigProvider).region,
  ),
);

/// "Аптеки": searches pharmacies in the maps app; tells the user when no
/// maps app or browser could be opened.
Future<void> openPharmacies(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final opened =
      await ref.read(pharmacySearchProvider).open(l10n.pharmacySearchQuery);
  if (!opened) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.pharmaciesUnavailable)));
  }
}
