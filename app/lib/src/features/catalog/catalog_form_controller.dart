import 'package:flutter/foundation.dart';

import '../../data/catalog/catalog_dto.dart';
import '../../data/catalog/catalog_link.dart';
import '../../data/catalog/manual_ingredient.dart';
import '../../data/db/database.dart';
import '../../data/repositories/local_writer.dart';
import 'catalog_fill.dart';

/// The catalog part of the medication form (ADR 0015 §4–§6): the link, the
/// replace offers, the consent box and the manual composition.
///
/// Nothing is sent from here. [draftLink] and [draftIngredients] say what
/// the save should write; null means "keep what is stored", so a form that
/// the person did not touch never unlinks or re-consents a medication.
class CatalogFormController extends ChangeNotifier {
  /// Creates the controller of a form whose medication stores [stored]
  /// (none for a new one) and [storedIngredients].
  CatalogFormController({
    this.stored = const CatalogLink.none(),
    List<ManualIngredient> storedIngredients = const [],
  })  : _link = stored,
        _ingredients = storedIngredients;

  /// The controller of the form of [row] (none for a new medication).
  factory CatalogFormController.fromRow(MedicationRow? row) {
    if (row == null) {
      return CatalogFormController();
    }
    List<ManualIngredient> ingredients;
    try {
      ingredients = ManualIngredient.decode(row.manualIngredients);
    } on DataException {
      ingredients = const []; // a corrupt stored list is not edited here
    }
    return CatalogFormController(
      stored: CatalogLink.fromRow(row),
      storedIngredients: ingredients,
    );
  }

  /// The references stored on the medication.
  final CatalogLink stored;

  CatalogLink _link;
  ProductCard? _card;
  bool _touched = false;
  bool _ticked = false;
  bool _consentWithdrawn = false;
  bool _hintDismissed = false;
  Map<CatalogTextField, String> _offers = const {};
  List<ManualIngredient> _ingredients;
  bool _ingredientsTouched = false;

  /// The references as the form has them now.
  CatalogLink get link => _link;

  /// Whether the form has a catalog link.
  bool get isLinked => _link.isLinked;

  /// The card of the product selected in this form; null for a link that
  /// was stored before.
  ProductCard? get card => _card;

  /// The "replace" offers still open.
  Map<CatalogTextField, String> get offers => _offers;

  /// Whether the person dismissed the substance overlap hint.
  bool get hintDismissed => _hintDismissed;

  /// The manual composition as the form has it now.
  List<ManualIngredient> get ingredients => _ingredients;

  /// Whether the (GTIN, product) pair of the form is the stored one.
  bool get isStoredPair => _link.samePair(stored);

  /// Whether the pair is already counted: nothing to ask again.
  bool get consentActive => stored.shared && isStoredPair && !_consentWithdrawn;

  /// Whether the opt-in box is offered: the link was made in this form, it
  /// is a pair with a shareable GTIN, and the pair is not already counted.
  /// Never pre-ticked.
  bool get canOfferConsent {
    final gtin = _link.gtin;
    return _touched &&
        gtin != null &&
        _link.productId != null &&
        isShareableGtin(gtin) &&
        !(stored.shared && isStoredPair);
  }

  /// Whether the box is ticked.
  bool get ticked => _ticked;

  /// The link to write: null keeps the stored one. A re-link carries
  /// `shared = false` unless the box was ticked in this flow, and a consent
  /// version only with that tick; an unchanged consented pair carries
  /// neither a version nor a new tick.
  CatalogLink? get draftLink {
    if (!_touched && !_consentWithdrawn) {
      return null;
    }
    final base = _link;
    if (_ticked && canOfferConsent) {
      return withConsentTick(base);
    }
    return CatalogLink(
      productId: base.productId,
      packageId: base.packageId,
      compositionId: base.compositionId,
      gtin: base.gtin,
      shared: consentActive,
    );
  }

  /// The manual composition to write; null keeps the stored one.
  List<ManualIngredient>? get draftIngredients =>
      _ingredientsTouched ? _ingredients : null;

  /// Links the form to [link] of [card]; [offers] are the catalog values
  /// for fields that already hold other text. Consent starts unticked.
  void select(
    CatalogLink link,
    ProductCard card,
    Map<CatalogTextField, String> offers,
  ) {
    _link = link;
    _card = card;
    _offers = offers;
    _touched = true;
    _ticked = false;
    _consentWithdrawn = false;
    _hintDismissed = false;
    notifyListeners();
  }

  /// Clears the references; the typed text stays.
  void unlink() {
    _link = const CatalogLink.none();
    _card = null;
    _offers = const {};
    _touched = true;
    _ticked = false;
    _consentWithdrawn = false;
    _hintDismissed = false;
    notifyListeners();
  }

  /// Ticks or unticks the opt-in box (ignored when it is not offered).
  void setTicked({required bool value}) {
    if (value && !canOfferConsent) {
      return;
    }
    _ticked = value;
    notifyListeners();
  }

  /// Stops counting the stored pair (the person switched it off).
  void withdrawConsent() {
    _consentWithdrawn = true;
    notifyListeners();
  }

  /// Closes the "replace" offer of [field] (accepted or declined).
  void closeOffer(CatalogTextField field) {
    _offers = {
      for (final entry in _offers.entries)
        if (entry.key != field) entry.key: entry.value,
    };
    notifyListeners();
  }

  /// Hides the overlap hint.
  void dismissHint() {
    _hintDismissed = true;
    notifyListeners();
  }

  /// Replaces the manual composition.
  void setIngredients(List<ManualIngredient> lines) {
    _ingredients = lines;
    _ingredientsTouched = true;
    notifyListeners();
  }

  List<IngredientOut> get _cardIngredients =>
      _card?.composition?.ingredients ?? const <IngredientOut>[];

  /// Catalog substance ids the overlap is computed from: the selected
  /// product's composition and the manual lines picked from the catalog.
  Set<String> get substanceIds {
    return {
      for (final line in _ingredients)
        if (line.substanceId case final id?) id,
      for (final ingredient in _cardIngredients) ingredient.substanceId,
    };
  }

  /// Display names (in [lang]) of the [substanceIds] that have one.
  Map<String, String> substanceNames(String lang) {
    final names = <String, String>{};
    for (final line in _ingredients) {
      final id = line.substanceId;
      if (id != null) {
        names[id] = line.name;
      }
    }
    for (final ingredient in _cardIngredients) {
      final name = localizedSubstanceName(ingredient, lang);
      if (name != null) {
        names[ingredient.substanceId] = name;
      }
    }
    return names;
  }
}
