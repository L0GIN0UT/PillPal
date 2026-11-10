import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/features/catalog/catalog_providers.dart';

import '../data/catalog_fixtures.dart';
import 'catalog_ui_env.dart';

// 4.10 privacy review: "already counted" is decided against the link the
// form will really write, i.e. with the scanned or typed GTIN, not against
// the GTIN printed on the catalog's card.

const CatalogLink _countedOnCardGtin = CatalogLink(
  productId: productA,
  packageId: '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33',
  compositionId: compositionA,
  gtin: shareableGtin,
  shared: true,
  consentVersion: 1,
);

Future<bool> _consented(
  WidgetTester tester, {
  required String? gtin,
}) async {
  final env = CatalogUiEnv();
  final container = await env.pump(tester);
  await env.seedLinked(container, link: _countedOnCardGtin);
  final pick = await container.read(catalogSelectionServiceProvider).pick(
        productA,
        profileId: null,
        gtin: gtin,
      );
  expect(pick.same, hasLength(1));
  return pick.same.single.consented;
}

void main() {
  testWidgets('a different scanned GTIN is not the counted pair',
      (tester) async {
    expect(await _consented(tester, gtin: otherShareableGtin), isFalse);
  });

  testWidgets('the same scanned GTIN is the counted pair', (tester) async {
    expect(await _consented(tester, gtin: shareableGtin), isTrue);
  });

  testWidgets('without a scanned GTIN the card GTIN decides', (tester) async {
    expect(await _consented(tester, gtin: null), isTrue);
  });

  testWidgets('the pick carries the link with the scanned GTIN',
      (tester) async {
    final env = CatalogUiEnv();
    final container = await env.pump(tester);
    final pick = await container.read(catalogSelectionServiceProvider).pick(
          productA,
          profileId: null,
          gtin: otherShareableGtin,
        );
    expect(pick.link.gtin, otherShareableGtin);
    expect(pick.link.packageId, isNull, reason: 'not the card package');
  });
}
