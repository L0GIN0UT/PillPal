import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_dto.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/catalog/manual_ingredient.dart';
import 'package:pillpal/src/features/catalog/catalog_fill.dart';
import 'package:pillpal/src/features/catalog/catalog_form_controller.dart';

import '../data/catalog_fixtures.dart';

// What the form tells the repository (ADR 0015 §4): an untouched form keeps
// what is stored, any re-link starts without consent, and the consent
// version travels only with a tick made in this flow.

final ProductCard _card = ProductCard.fromJson(cardJson());
// A scanned number the card does not list (a card that lists it means the
// catalog knows the pair, so no box).
final CatalogLink _link = withGtin(
  catalogLinkOf(_card),
  otherShareableGtin,
  card: _card,
);

const CatalogLink _consented = CatalogLink(
  productId: productA,
  compositionId: compositionA,
  gtin: otherShareableGtin,
  shared: true,
);

void main() {
  test('an untouched form keeps the stored link and composition', () {
    final form = CatalogFormController(
      stored: _consented,
      storedIngredients: const [ManualIngredient(name: 'Salt')],
    );

    expect(form.draftLink, isNull);
    expect(form.draftIngredients, isNull);
    expect(form.canOfferConsent, isFalse, reason: 'only at link time');
  });

  test('a text search never offers the box', () {
    final form = CatalogFormController()..select(_link, _card, const {});

    final draft = form.draftLink!;
    expect(draft.productId, productA);
    expect(draft.shared, isFalse);
    expect(draft.consentVersion, isNull);
    expect(form.canOfferConsent, isFalse);
    form.setTicked(value: true);
    expect(form.draftLink!.shared, isFalse);
  });

  for (final source in [GtinSource.scanned, GtinSource.typed]) {
    test('a $source GTIN offers the box, unticked', () {
      final form = CatalogFormController()
        ..select(_link, _card, const {}, gtinSource: source);

      expect(form.canOfferConsent, isTrue);
      expect(form.ticked, isFalse, reason: 'never pre-ticked');
      expect(form.draftLink!.shared, isFalse);
      expect(form.draftLink!.consentVersion, isNull);
    });
  }

  test('a tick sends the consent version once', () {
    final form = CatalogFormController()
      ..select(_link, _card, const {}, gtinSource: GtinSource.scanned)
      ..setTicked(value: true);

    final draft = form.draftLink!;
    expect(draft.shared, isTrue);
    expect(draft.consentVersion, 1);
  });

  test('re-linking to another product resets a stored consent', () {
    final form = CatalogFormController(stored: _consented);
    final other = ProductCard.fromJson(cardJson(productId: productB));
    expect(form.consentActive, isTrue);

    form.select(
      withGtin(catalogLinkOf(other), otherShareableGtin, card: other),
      other,
      const {},
      gtinSource: GtinSource.typed,
    );

    final draft = form.draftLink!;
    expect(draft.productId, productB);
    expect(draft.shared, isFalse);
    expect(draft.consentVersion, isNull);
    expect(form.consentActive, isFalse);
    expect(form.canOfferConsent, isTrue, reason: 'a new pair asks again');
  });

  test('the same consented pair is not asked again and sends no version', () {
    final form = CatalogFormController(stored: _consented)
      ..select(_link, _card, const {});

    expect(form.canOfferConsent, isFalse);
    final draft = form.draftLink!;
    expect(draft.shared, isTrue);
    expect(draft.consentVersion, isNull);
  });

  test('a tick is ignored when the box is not offered', () {
    const restricted = CatalogLink(productId: productA, gtin: restrictedGtin);
    final form = CatalogFormController()
      ..select(restricted, _card, const {}, gtinSource: GtinSource.typed)
      ..setTicked(value: true);

    expect(form.canOfferConsent, isFalse);
    expect(form.draftLink!.shared, isFalse);
    expect(form.draftLink!.consentVersion, isNull);
  });

  test('no box without a GTIN, i.e. for a product with several packages', () {
    const noGtin = CatalogLink(productId: productA);
    final form = CatalogFormController()..select(noGtin, _card, const {});

    expect(form.canOfferConsent, isFalse);
  });

  test('switching the counting off writes the same pair unshared', () {
    final form = CatalogFormController(stored: _consented)..withdrawConsent();

    final draft = form.draftLink!;
    expect(draft.productId, productA);
    expect(draft.shared, isFalse);
    expect(draft.consentVersion, isNull);
    expect(form.consentActive, isFalse);
  });

  test('a withdrawal sticks across unlink and re-selection until resumed', () {
    final form = CatalogFormController(stored: _consented)..withdrawConsent();

    form
      ..unlink()
      ..select(_link, _card, const {});

    expect(form.showConsentSwitch, isTrue);
    expect(form.consentActive, isFalse);
    expect(form.draftLink!.shared, isFalse);

    form.resumeConsent();
    expect(form.consentActive, isTrue);
    expect(form.draftLink!.shared, isTrue);
    expect(form.draftLink!.consentVersion, isNull);
  });

  test('unlinking clears the references and any tick', () {
    final form = CatalogFormController()
      ..select(_link, _card, const {}, gtinSource: GtinSource.typed)
      ..setTicked(value: true)
      ..unlink();

    final draft = form.draftLink!;
    expect(draft.isLinked, isFalse);
    expect(draft.shared, isFalse);
    expect(form.isLinked, isFalse);
  });

  test('offers close one by one', () {
    final form = CatalogFormController()
      ..select(_link, _card, {
        CatalogTextField.name: 'A',
        CatalogTextField.form: 'B',
      })
      ..closeOffer(CatalogTextField.name);

    expect(form.offers, {CatalogTextField.form: 'B'});
  });

  test('the overlap candidate is the product plus the picked substances', () {
    final form = CatalogFormController()
      ..select(_link, _card, const {})
      ..setIngredients(const [
        ManualIngredient(name: 'Free text'),
        ManualIngredient(name: 'Picked', substanceId: substanceY),
      ]);

    expect(form.substanceIds, {substanceX, substanceY});
    expect(form.substanceNames('en'), {
      substanceX: 'Substance',
      substanceY: 'Picked',
    });
    expect(form.substanceNames('ru')[substanceX], 'Вещество');
    expect(form.draftIngredients, hasLength(2));
  });

  test('a private number is a link without product that is never counted', () {
    final form = CatalogFormController()..selectPrivateGtin(shareableGtin);

    expect(form.isLinked, isTrue);
    expect(form.canOfferConsent, isFalse);
    form.setTicked(value: true);
    final draft = form.draftLink!;
    expect(draft.gtin, shareableGtin);
    expect(draft.productId, isNull);
    expect(draft.shared, isFalse);
    expect(draft.consentVersion, isNull);
  });

  test('unlinking removes a private number', () {
    final form = CatalogFormController()
      ..selectPrivateGtin(restrictedGtin)
      ..unlink();

    expect(form.isLinked, isFalse);
  });

  test('no box when the card already lists the scanned number', () {
    final listed = withGtin(catalogLinkOf(_card), shareableGtin, card: _card);
    final form = CatalogFormController()
      ..select(listed, _card, const {}, gtinSource: GtinSource.scanned);

    expect(form.canOfferConsent, isFalse);
  });
}
