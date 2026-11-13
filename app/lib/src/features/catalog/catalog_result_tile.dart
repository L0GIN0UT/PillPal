import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/compact_rows.dart';
import '../common/compact_text.dart';
import '../common/dosage_form.dart';
import '../common/dosage_form_avatar.dart';
import '../common/gap.dart';
import '../common/icon_label.dart';
import '../common/text_fit.dart';

/// One search result as a row of the results card (board
/// B2-AddMedication): a soft tile with the icon of the dosage form, the
/// name, substances, maker and form, the country label of a foreign-market
/// product (D6) and the withdrawn label.
/// From the compact text scale on, or where a word would break beside them
/// (a Galaxy Z Fold cover screen), the tile and the chevron go away and the
/// whole row stays tappable (B2-README section 9.7); the rows of one card
/// (a `CompactGroup`) do so together. It measures in a `LayoutBuilder`.
class CatalogResultTile extends StatelessWidget implements NarrowAware {
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

  String get _details => [
        if (result.substances.isNotEmpty) result.substances.join(', '),
        if (result.manufacturer case final manufacturer?) manufacturer,
        if (result.form case final form?) form,
      ].join(' · ');

  /// The side paddings, the tile and the chevron beside the text.
  static const double _reserved = 2 * PillPalSpacing.lg +
      PillPalSizes.avatarSm +
      PillPalSpacing.md +
      PillPalSpacing.sm +
      PillPalSizes.iconInline;

  /// The row width for the tile and the chevron beside the name and the
  /// details with no word broken inside.
  @override
  double fullLayoutWidth(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return _reserved +
        longestWordOf(context, [
          (result.name, textTheme.rowTitleStrong),
          (_details, textTheme.bodySmall),
        ]);
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    final full = fullLayoutWidth(context);
    return LayoutBuilder(
      builder: (context, constraints) => _row(
        context,
        details,
        compact: isCompactText(context) ||
            CompactRows.of(context) ||
            constraints.maxWidth < full,
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String details, {
    required bool compact,
  }) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: ValueKey('catalog-result-${result.id}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: context.metrics.isSenior
              ? PillPalSizes.listRowMinSenior
              : PillPalSizes.listRowMin,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PillPalSpacing.lg,
            vertical: PillPalSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!compact) ...[
                DosageFormAvatar(form: dosageFormOf(result.form)),
                const Gap.h(PillPalSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(result.name, style: textTheme.rowTitleStrong),
                    if (details.isNotEmpty)
                      Text(details, style: textTheme.bodySmall),
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
              if (!compact) ...[
                const Gap.h(PillPalSpacing.sm),
                ExcludeSemantics(
                  child: Icon(
                    Icons.chevron_right,
                    size: PillPalSizes.iconInline,
                    color: palette.inkMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
