import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/catalog/catalog_cache_repository.dart';
import '../../data/catalog/catalog_dto.dart';
import '../../data/catalog/catalog_link.dart';
import '../../data/config.dart';
import '../../data/repositories/validation.dart';

// What a catalog product contributes to the medication form (ADR 0015 §5,
// owner decision D5). Pure functions; no widgets and no IO.

/// The free-text fields a catalog product can fill.
enum CatalogTextField {
  /// Medication name.
  name,

  /// Dosage form.
  form,

  /// Strength.
  strength,
}

/// Where the GTIN of a link came from. The opt-in to count a (GTIN, product)
/// pair is offered only for a number the person scanned or typed
/// (ADR 0015 section 4): a GTIN merely read from the catalog's own card
/// proves nothing about the package in their hand.
enum GtinSource {
  /// From the catalog's card (a text search): no opt-in.
  catalog,

  /// Scanned with the camera (4.11).
  scanned,

  /// Typed by the person (4.11).
  typed,
}

/// What selecting a product does to the typed text: [fills] go to empty
/// fields, [offers] are catalog values for fields that already have other
/// text, shown as an explicit "replace" offer (nothing is overwritten
/// silently).
@immutable
class CatalogFill {
  /// Creates a plan.
  const CatalogFill({this.fills = const {}, this.offers = const {}});

  /// Values for the empty fields.
  final Map<CatalogTextField, String> fills;

  /// Catalog values for the filled fields whose text differs.
  final Map<CatalogTextField, String> offers;
}

/// The texts of [card] in [lang] (`ru` or `en`), already within the limits
/// of the medication fields; fields the card has nothing for are absent.
Map<CatalogTextField, String> catalogTexts(ProductCard card, String lang) {
  final texts = <CatalogTextField, String>{};
  void put(CatalogTextField field, String? value, int max) {
    final text = value?.trim() ?? '';
    if (text.isNotEmpty) {
      texts[field] = _clip(text, max);
    }
  }

  final composition = card.composition;
  put(CatalogTextField.name, card.product.name, FieldLimits.medicationName);
  put(
    CatalogTextField.form,
    composition == null ? null : localizedFormName(composition, lang),
    FieldLimits.shortText,
  );
  put(
    CatalogTextField.strength,
    composition == null ? null : strengthText(composition),
    FieldLimits.shortText,
  );
  return texts;
}

/// The plan for selecting [card] when the form holds [current] (a missing
/// key is an empty field).
CatalogFill planFill(
  ProductCard card, {
  required String lang,
  required Map<CatalogTextField, String> current,
}) {
  final fills = <CatalogTextField, String>{};
  final offers = <CatalogTextField, String>{};
  for (final entry in catalogTexts(card, lang).entries) {
    final typed = (current[entry.key] ?? '').trim();
    if (typed.isEmpty) {
      fills[entry.key] = entry.value;
    } else if (typed != entry.value) {
      // Exact comparison on purpose: a different case or spelling is still
      // the person's own text and gets an offer, never a silent overwrite.
      offers[entry.key] = entry.value;
    }
  }
  return CatalogFill(fills: fills, offers: offers);
}

/// The references of a medication linked to [card]. The package and GTIN
/// are set only when the product has exactly one current package with a
/// valid GTIN: with several the person has not said which one they hold
/// (the scanner of 4.11 supplies the GTIN of the scanned one).
CatalogLink catalogLinkOf(ProductCard card) {
  final current = card.packages.where((package) => !package.withdrawn);
  final single = current.length == 1 ? current.first : null;
  return CatalogLink(
    productId: card.product.id,
    packageId: single?.id,
    compositionId: card.composition?.id,
    gtin: single == null ? null : _firstGtin14(single),
  );
}

/// [link] with the opt-in ticked: `shared` with the consent version this
/// app records. Only for a link made in a flow where the box was ticked.
CatalogLink withConsentTick(CatalogLink link) {
  return CatalogLink(
    productId: link.productId,
    packageId: link.packageId,
    compositionId: link.compositionId,
    gtin: link.gtin,
    shared: true,
    consentVersion: CatalogPolicy.currentConsentVersion,
  );
}

/// [link] with [gtin] (any valid GTIN, stored as GTIN-14) instead of the
/// one of the card; [link] unchanged when [gtin] is not a valid number.
/// With the product's [card], the package that carries this GTIN is set
/// even when the product has several.
CatalogLink withGtin(CatalogLink link, String gtin, {ProductCard? card}) {
  final String gtin14;
  try {
    gtin14 = normalizeGtin(gtin).gtin14;
  } on GtinException {
    return link;
  }
  return CatalogLink(
    productId: link.productId,
    // A package is kept only if it is the one with this GTIN.
    packageId: packageCarryingGtin(card, gtin14) ??
        (gtin14 == link.gtin ? link.packageId : null),
    compositionId: link.compositionId,
    gtin: gtin14,
  );
}

/// Keeps [card] in the on-device cache when a medication references it. A
/// cache failure must never make a successful save look failed, so it is
/// swallowed here (the card is fetched again when it is next opened).
Future<void> rememberCardBestEffort(
  CatalogCacheRepository cache,
  ProductCard card,
) async {
  try {
    await cache.remember(card);
  } on Object {
    // Best effort by design; nothing about the card is logged.
  }
}

/// Name of the dosage form of [composition] in [lang], falling back to the
/// other language.
String? localizedFormName(CompositionOut composition, String lang) {
  return _localized(composition.formNameRu, composition.formNameEn, lang);
}

/// Name of [ingredient] in [lang], falling back to the other language.
String? localizedSubstanceName(IngredientOut ingredient, String lang) {
  return _localized(ingredient.nameRu, ingredient.nameEn, lang);
}

/// "500 mg" or "5 mg/1 ml" of [ingredient]; null without a strength.
String? ingredientStrength(IngredientOut ingredient) {
  final value = ingredient.strengthValue;
  if (value == null || value.isEmpty) {
    return null;
  }
  final unit = ingredient.strengthUnit;
  final base = unit == null || unit.isEmpty ? value : '$value $unit';
  final per = [
    if (ingredient.perValue != null) ingredient.perValue,
    if (ingredient.perUnit != null) ingredient.perUnit,
  ].join(' ');
  return per.isEmpty ? base : '$base/$per';
}

/// The strengths of the ingredients of [composition], joined with " + ".
String? strengthText(CompositionOut composition) {
  final strengths = [
    for (final ingredient in composition.ingredients)
      if (ingredientStrength(ingredient) case final strength?) strength,
  ];
  return strengths.isEmpty ? null : strengths.join(' + ');
}

/// Whether [gtin] may be sent to the catalog and counted
/// (`docs/spec/gtin.md` §3): valid and not a restricted number.
bool isShareableGtin(String gtin) {
  try {
    return normalizeGtin(gtin).classification == GtinClassification.shareable;
  } on GtinException {
    return false;
  }
}

String? _localized(String? ru, String? en, String lang) {
  final first = lang == 'ru' ? ru : en;
  final second = lang == 'ru' ? en : ru;
  for (final value in [first, second]) {
    if (value != null && value.trim().isNotEmpty) {
      return value;
    }
  }
  return null;
}

/// The current package of [card] that carries [gtin14], if any.
String? packageCarryingGtin(ProductCard? card, String gtin14) {
  if (card == null) {
    return null;
  }
  for (final package in card.packages) {
    if (!package.withdrawn &&
        package.gtins.any((g) => _gtin14Of(g) == gtin14)) {
      return package.id;
    }
  }
  return null;
}

String? _gtin14Of(String gtin) {
  try {
    return normalizeGtin(gtin).gtin14;
  } on GtinException {
    return null;
  }
}

String? _firstGtin14(PackageOut package) {
  for (final gtin in package.gtins) {
    try {
      return normalizeGtin(gtin).gtin14;
    } on GtinException {
      continue;
    }
  }
  return null;
}

String _clip(String text, int max) {
  final runes = text.runes;
  return runes.length <= max ? text : String.fromCharCodes(runes.take(max));
}
