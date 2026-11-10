import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'catalog_fill.dart';

/// The explicit "replace" offer of D5: a catalog value for a field that
/// already has other text. The text stays as typed until it is accepted.
class ReplaceOfferTile extends StatelessWidget {
  /// Creates the offer of [value] for [field].
  const ReplaceOfferTile({
    required this.field,
    required this.value,
    required this.onReplace,
    required this.onKeep,
    super.key,
  });

  /// The field the value is for.
  final CatalogTextField field;

  /// The catalog's text.
  final String value;

  /// Accepts the offer: the field takes [value].
  final VoidCallback onReplace;

  /// Declines it: the typed text stays.
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = switch (field) {
      CatalogTextField.name => l10n.medNameLabel,
      CatalogTextField.form => l10n.medFormLabel,
      CatalogTextField.strength => l10n.medStrengthLabel,
    };
    return Card(
      key: ValueKey('catalog-offer-${field.name}'),
      child: Padding(
        padding: PillPalSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.catalogReplaceOffer(label, value)),
            const Gap.v(PillPalSpacing.sm),
            Wrap(
              spacing: PillPalSpacing.sm,
              runSpacing: PillPalSpacing.sm,
              children: [
                TextButton(
                  key: ValueKey('catalog-offer-keep-${field.name}'),
                  onPressed: onKeep,
                  child: Text(l10n.catalogKeepMine),
                ),
                FilledButton(
                  key: ValueKey('catalog-offer-replace-${field.name}'),
                  onPressed: onReplace,
                  child: Text(l10n.catalogReplace),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The linked catalog product of the form: its name when known, the card
/// and "unlink" (which keeps the typed text).
class LinkedProductTile extends StatelessWidget {
  /// Creates the tile; [name] is null for a link stored earlier.
  const LinkedProductTile({
    required this.onOpenCard,
    required this.onUnlink,
    this.name,
    super.key,
  });

  /// Product name, when the card was opened in this form.
  final String? name;

  /// Opens the product card; null when the link has no product.
  final VoidCallback? onOpenCard;

  /// Clears the references.
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final productName = name;
    return Card(
      key: const Key('catalog-linked'),
      child: Padding(
        padding: PillPalSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.catalogLinkedTitle, style: textTheme.titleSmall),
            if (productName != null)
              Text(
                productName,
                key: const Key('catalog-linked-name'),
                style: textTheme.bodyMedium,
              ),
            Text(l10n.catalogLinkedNote, style: textTheme.bodySmall),
            const Gap.v(PillPalSpacing.sm),
            Wrap(
              spacing: PillPalSpacing.sm,
              runSpacing: PillPalSpacing.sm,
              children: [
                TextButton(
                  key: const Key('catalog-open-card'),
                  onPressed: onOpenCard,
                  child: Text(l10n.catalogOpenCard),
                ),
                TextButton(
                  key: const Key('catalog-unlink'),
                  onPressed: onUnlink,
                  child: Text(l10n.catalogUnlink),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
