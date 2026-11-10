import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_dto.dart';
import 'package:pillpal/src/features/catalog/catalog_fill.dart';

import '../data/catalog_fixtures.dart';

// What a catalog product contributes to the form (D5): empty fields are
// filled, filled ones only get an offer; the references follow the card.

ProductCard _card({
  List<Map<String, Object?>>? packages,
  bool withComposition = true,
}) {
  final json = cardJson(compositionId: withComposition ? compositionA : null);
  if (packages != null) {
    json['packages'] = packages;
  }
  return ProductCard.fromJson(json);
}

Map<String, Object?> _package(
  String id, {
  List<String> gtins = const [shareableGtin],
  bool withdrawn = false,
}) {
  return {
    'id': id,
    'gtins': gtins,
    'count': '30',
    'count_unit': 'tablet',
    'description': null,
    'withdrawn': withdrawn,
  };
}

const String _packageOne = '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33';
const String _packageTwo = '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a34';

void main() {
  group('planFill', () {
    test('fills every empty field from the card', () {
      final plan = planFill(_card(), lang: 'en', current: const {});

      expect(plan.fills, {
        CatalogTextField.name: 'Synthetic Tablet',
        CatalogTextField.form: 'tablets',
        CatalogTextField.strength: '500 mg',
      });
      expect(plan.offers, isEmpty);
    });

    test('uses the Russian names for the Russian UI', () {
      final plan = planFill(_card(), lang: 'ru', current: const {});

      expect(plan.fills[CatalogTextField.form], 'таблетки');
    });

    test('a filled field is never filled, it gets an offer instead', () {
      final plan = planFill(
        _card(),
        lang: 'en',
        current: {
          CatalogTextField.name: 'My own name',
          CatalogTextField.form: '   ',
        },
      );

      expect(plan.fills.keys, {
        CatalogTextField.form,
        CatalogTextField.strength,
      });
      expect(plan.offers, {CatalogTextField.name: 'Synthetic Tablet'});
    });

    test('the same text needs no offer', () {
      final plan = planFill(
        _card(),
        lang: 'en',
        current: {CatalogTextField.name: '  Synthetic Tablet '},
      );

      expect(plan.offers, isEmpty);
      expect(plan.fills.containsKey(CatalogTextField.name), isFalse);
    });

    test('a product without a composition fills only the name', () {
      final plan = planFill(
        _card(withComposition: false),
        lang: 'en',
        current: const {},
      );

      expect(plan.fills.keys, {CatalogTextField.name});
    });
  });

  group('catalogLinkOf', () {
    test('a single current package sets the package and its GTIN-14', () {
      final link = catalogLinkOf(_card());

      expect(link.productId, productA);
      expect(link.compositionId, compositionA);
      expect(link.packageId, _packageOne);
      expect(link.gtin, shareableGtin);
      expect(link.shared, isFalse);
      expect(link.consentVersion, isNull);
    });

    test('several packages leave the package open', () {
      final link = catalogLinkOf(
        _card(packages: [_package(_packageOne), _package(_packageTwo)]),
      );

      expect(link.productId, productA);
      expect(link.packageId, isNull);
      expect(link.gtin, isNull);
    });

    test('a withdrawn package is not counted', () {
      final link = catalogLinkOf(
        _card(
          packages: [
            _package(_packageOne),
            _package(_packageTwo, withdrawn: true),
          ],
        ),
      );

      expect(link.packageId, _packageOne);
    });

    test('a GTIN-13 is stored as GTIN-14', () {
      final link = catalogLinkOf(
        _card(
          packages: [
            _package(_packageOne, gtins: ['4607000000007']),
          ],
        ),
      );

      expect(link.gtin, shareableGtin);
    });
  });

  test('a strength with a per-unit reads as a ratio', () {
    final composition = CompositionOut.fromJson({
      'id': compositionA,
      'complete': true,
      'withdrawn': false,
      'form_code': null,
      'form_name_ru': null,
      'form_name_en': null,
      'ingredients': [
        {
          'substance_id': substanceX,
          'name_ru': null,
          'name_en': 'Substance',
          'strength_value': '5',
          'strength_unit': 'mg',
          'per_value': '1',
          'per_unit': 'ml',
        },
        {
          'substance_id': substanceY,
          'name_ru': null,
          'name_en': 'Other',
          'strength_value': null,
          'strength_unit': null,
          'per_value': null,
          'per_unit': null,
        },
      ],
    });

    expect(strengthText(composition), '5 mg/1 ml');
    expect(localizedFormName(composition, 'en'), isNull);
  });

  test('isShareableGtin rejects restricted and malformed numbers', () {
    expect(isShareableGtin(shareableGtin), isTrue);
    expect(isShareableGtin(restrictedGtin), isFalse);
    expect(isShareableGtin('123'), isFalse);
  });

  group('withGtin', () {
    final twoPackages = ProductCard.fromJson({
      ...cardJson(),
      'packages': [
        for (final (id, gtin) in [
          ('7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33', shareableGtin),
          ('7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a34', otherShareableGtin),
        ])
          {
            'id': id,
            'gtins': [gtin],
            'count': '30',
            'count_unit': 'tablet',
            'description': null,
            'withdrawn': false,
          },
      ],
    });

    test('the scanned number picks its package among several', () {
      final link = withGtin(
        catalogLinkOf(twoPackages),
        otherShareableGtin,
        card: twoPackages,
      );

      expect(link.gtin, otherShareableGtin);
      expect(link.packageId, '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a34');
    });

    test('a number of no package of the card sets no package', () {
      final link = withGtin(
        catalogLinkOf(twoPackages),
        '04607000000021',
        card: twoPackages,
      );

      expect(link.gtin, '04607000000021');
      expect(link.packageId, isNull);
    });
  });
}
