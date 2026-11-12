import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/status_message.dart';
import '../pharmacies/pharmacy_providers.dart';
import 'catalog_providers.dart';

/// Settings -> catalog data sources: where the medication catalog comes
/// from, with the attribution and license each source asks for
/// (`GET /v1/sources`). Offline it says the list needs a connection.
class CatalogSourcesScreen extends ConsumerWidget {
  /// Creates the screen.
  const CatalogSourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final sources = ref.watch(catalogSourcesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.catalogSourcesTile)),
      body: sources.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ListView(
          padding: PillPalSpacing.form,
          children: [
            StatusMessage(
              key: const Key('catalog-sources-offline'),
              icon: Icons.wifi_off,
              text: l10n.catalogSourcesOffline,
              action: TextButton(
                key: const Key('catalog-sources-retry'),
                onPressed: () => ref.invalidate(catalogSourcesProvider),
                child: Text(l10n.catalogRetry),
              ),
            ),
          ],
        ),
        data: (items) => ListView(
          padding: PillPalSpacing.form,
          children: [
            Text(l10n.catalogSourcesIntro),
            const Gap.v(PillPalSpacing.lg),
            for (final source in items) ...[
              _SourceCard(source: source),
              const Gap.v(PillPalSpacing.md),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceCard extends ConsumerWidget {
  const _SourceCard({required this.source});

  final CatalogSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final url = Uri.tryParse(source.url);
    return Card(
      key: ValueKey('catalog-source-${source.code}'),
      child: Padding(
        padding: PillPalSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(source.name, style: textTheme.titleSmall),
            const Gap.v(PillPalSpacing.xs),
            Text(source.attribution, style: textTheme.bodyMedium),
            const Gap.v(PillPalSpacing.xs),
            Text(
              l10n.catalogSourceLicense(source.license),
              style: textTheme.bodySmall,
            ),
            if (url != null && url.hasAuthority)
              TextButton(
                key: ValueKey('catalog-source-open-${source.code}'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  alignment: AlignmentDirectional.centerStart,
                ),
                onPressed: () => ref.read(urlOpenerProvider).open(url),
                child: Text(source.url),
              ),
          ],
        ),
      ),
    );
  }
}
