import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/catalog/catalog_dto.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/icon_label.dart';
import '../common/pillpal_banner.dart';
import '../common/sheet_scaffold.dart';
import '../common/status_message.dart';
import 'catalog_fill.dart';
import 'catalog_lang.dart';
import 'catalog_providers.dart';

/// Opens the card of product [productId]: the cached card (offline too),
/// refreshed when it is older than 30 days (ADR 0015 §2).
Future<void> showProductCardSheet(BuildContext context, String productId) {
  return showPillPalSheet<void>(
    context,
    (context) => ProductCardSheet(productId: productId),
  );
}

/// The sheet around [ProductCardView]: loads the card and the attribution.
class ProductCardSheet extends ConsumerWidget {
  /// Creates the sheet.
  const ProductCardSheet({required this.productId, super.key});

  /// Catalog product id.
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final card = ref.watch(catalogCardProvider(productId));
    final sources = ref.watch(catalogSourcesProvider).valueOrNull;
    return SingleChildScrollView(
      padding: PillPalSpacing.sheet,
      child: card.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => _offline(l10n),
        data: (value) => value == null
            ? _offline(l10n)
            : ProductCardView(card: value, sources: sources),
      ),
    );
  }
}

Widget _offline(AppLocalizations l10n) {
  return StatusMessage(
    key: const Key('product-card-offline'),
    icon: Icons.wifi_off,
    text: l10n.catalogCardOffline,
  );
}

/// A catalog product card: what the catalog says, with its source, a
/// "withdrawn" label and the note that the data may be incomplete. Nothing
/// here is advice.
class ProductCardView extends StatelessWidget {
  /// Creates the view; [sources] is null while the attribution is not
  /// known (offline), then only the source code is named.
  const ProductCardView({required this.card, this.sources, super.key});

  /// The card.
  final ProductCard card;

  /// Attribution of the catalog's sources, when known.
  final List<CatalogSource>? sources;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final lang = catalogLanguage(context);
    final product = card.product;
    final composition = card.composition;
    final form =
        composition == null ? null : localizedFormName(composition, lang);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          product.name,
          key: const Key('product-card-name'),
          style: textTheme.titleLarge,
        ),
        if (product.withdrawn || (composition?.withdrawn ?? false)) ...[
          const Gap.v(PillPalSpacing.sm),
          IconLabel(
            key: const Key('product-card-withdrawn'),
            icon: Icons.history,
            text: l10n.catalogWithdrawn,
          ),
        ],
        const Gap.v(PillPalSpacing.sm),
        ..._facts(l10n, textTheme, form),
        const Gap.v(PillPalSpacing.lg),
        ..._composition(l10n, textTheme, lang),
        ..._packages(l10n, textTheme),
        const Gap.v(PillPalSpacing.lg),
        PillPalBanner(tone: BannerTone.info, body: l10n.catalogDataNote),
        const Gap.v(PillPalSpacing.sm),
        ..._attribution(l10n, textTheme),
      ],
    );
  }

  List<Widget> _facts(
    AppLocalizations l10n,
    TextTheme textTheme,
    String? form,
  ) {
    final product = card.product;
    final lines = [
      if (product.manufacturer case final name?)
        l10n.catalogCardManufacturer(name),
      if (product.country case final country?) l10n.catalogCountry(country),
      if (form != null) l10n.catalogCardForm(form),
      if (product.registrationNumber case final number?)
        l10n.catalogCardRegistration(number),
    ];
    return [for (final line in lines) Text(line, style: textTheme.bodyMedium)];
  }

  List<Widget> _composition(
    AppLocalizations l10n,
    TextTheme textTheme,
    String lang,
  ) {
    final composition = card.composition;
    final children = <Widget>[
      Text(l10n.catalogCardComposition, style: textTheme.titleMedium),
      const Gap.v(PillPalSpacing.xs),
    ];
    if (composition == null) {
      children.add(
        StatusMessage(
          icon: Icons.info_outline,
          text: l10n.catalogCardNoComposition,
        ),
      );
      return children;
    }
    for (final ingredient in composition.ingredients) {
      final name = localizedSubstanceName(ingredient, lang) ?? '';
      final strength = ingredientStrength(ingredient);
      children.add(
        Text(
          strength == null ? name : '$name $strength',
          style: textTheme.bodyMedium,
        ),
      );
    }
    if (!composition.complete) {
      children
        ..add(const Gap.v(PillPalSpacing.xs))
        ..add(
          PillPalBanner(
            key: const Key('product-card-incomplete'),
            tone: BannerTone.info,
            body: l10n.catalogCardCompositionIncomplete,
          ),
        );
    }
    return children;
  }

  List<Widget> _packages(AppLocalizations l10n, TextTheme textTheme) {
    final counts = [
      for (final package in card.packages)
        if (package.count case final count? when !package.withdrawn) count,
    ];
    if (counts.isEmpty) {
      return const [];
    }
    return [
      const Gap.v(PillPalSpacing.lg),
      Text(l10n.catalogCardPackages, style: textTheme.titleMedium),
      const Gap.v(PillPalSpacing.xs),
      for (final count in counts)
        Text(l10n.catalogCardPackage(count), style: textTheme.bodyMedium),
    ];
  }

  List<Widget> _attribution(AppLocalizations l10n, TextTheme textTheme) {
    final code = card.product.source;
    final known = sources;
    CatalogSource? source;
    if (known != null) {
      for (final candidate in known) {
        if (candidate.code == code) {
          source = candidate;
        }
      }
    }
    return [
      Text(
        l10n.catalogCardSource(source?.name ?? code),
        key: const Key('product-card-source'),
        style: textTheme.bodySmall,
      ),
      if (source != null)
        Text(
          source.attribution,
          key: const Key('product-card-attribution'),
          style: textTheme.bodySmall,
        ),
    ];
  }
}
