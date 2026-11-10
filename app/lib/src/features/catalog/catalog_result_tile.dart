import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/icon_label.dart';

/// One search result: name, substances, maker and form, the country label
/// of a foreign-market product (D6) and the withdrawn label.
class CatalogResultTile extends StatelessWidget {
  /// Creates the tile; [foreign] marks a product of another market.
  const CatalogResultTile({
    required this.result,
    required this.foreign,
    required this.onTap,
    super.key,
  });

  /// The result.
  final SearchResult result;

  /// Whether the product belongs to another market than the build's.
  final bool foreign;

  /// Called when the tile is tapped.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final details = [
      if (result.substances.isNotEmpty) result.substances.join(', '),
      if (result.manufacturer case final manufacturer?) manufacturer,
      if (result.form case final form?) form,
    ].join(' · ');
    return Card(
      key: ValueKey('catalog-result-${result.id}'),
      child: InkWell(
        borderRadius: PillPalRadius.card,
        onTap: onTap,
        child: Padding(
          padding: PillPalSpacing.card,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.name, style: textTheme.titleSmall),
              if (details.isNotEmpty) Text(details, style: textTheme.bodySmall),
              if (foreign) ...[
                const Gap.v(PillPalSpacing.xs),
                IconLabel(
                  key: ValueKey('catalog-country-${result.id}'),
                  icon: Icons.public,
                  text: l10n.catalogCountry(
                    result.country ?? result.market.toUpperCase(),
                  ),
                ),
              ],
              if (result.withdrawn) ...[
                const Gap.v(PillPalSpacing.xs),
                IconLabel(
                  key: ValueKey('catalog-withdrawn-${result.id}'),
                  icon: Icons.history,
                  text: l10n.catalogWithdrawn,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
