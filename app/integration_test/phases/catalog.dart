import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/catalog/catalog_providers.dart';
import 'package:pillpal/src/routing/router.dart';

import '../support/app_driver.dart';

/// A package number of the synthetic fixture product "Testamol 500" (the
/// catalog is loaded with `catalog/tests/fixtures/fixture/v1`).
const String knownGtin = '4607012345677';
const String knownGtin14 = '04607012345677';

/// A valid, shareable number no fixture product carries, and the same number
/// with a wrong check digit.
const String unknownGtin = '4601234567893';
const String unknownGtin14 = '04601234567893';
const String mistypedGtin = '4601234567890';

/// Polls between taps of the manual-entry button while the field is absent.
const int _retryEveryPolls = 10;

/// The synthetic product the person finds by name for the unknown number.
const String unknownProductSearch = 'Fixtocombo';

/// Phase `catalog` (after `relatives`: the signed-in app, no camera): the
/// manual number path of the scan sheet (docs/phase4-plan.md 4.12).
///
/// 1. a typed number of a known package selects its product (the catalog
///    answers `found`), the form fills its name, the medication is saved with
///    the references;
/// 2. a mistyped number is refused on the device; the valid unknown number
///    asks what to do, the person finds the product by name, and the
///    medication is saved with the number and the product (no opt-in box:
///    this backend does not accept contributions).
///
/// The workflow then checks that the backend holds both links.
Future<void> catalogPhase(WidgetTester tester) async {
  final container = await launchApp(tester);
  await waitFor(tester, find.byType(NavigationBar), reason: 'Today');
  expect(
    container.read(catalogEnabledProvider),
    isTrue,
    reason: 'the build carries a catalog URL',
  );
  final db = container.read(databaseProvider);

  await _addMedication(tester, container, () async {
    await _typeNumber(tester, knownGtin);
    await waitFor(
      tester,
      find.byKey(const Key('catalog-linked')),
      reason: 'the known number to select its product',
    );
  });
  final api = container.read(catalogApiProvider)!;
  final lookup = await api.lookupGtin(knownGtin);
  expect(lookup.status, 'found');
  final known = await _medicationWithGtin(db, knownGtin14);
  expect(known.catalogProductId, lookup.product?.id);
  expect(known.catalogPackageId, lookup.package?.id);
  expect(known.name, lookup.product?.name, reason: 'the form was filled');
  expect(known.gtinLinkShared, isFalse);

  await _addMedication(tester, container, () async {
    await _typeNumber(tester, mistypedGtin, submit: false);
    await tapVisible(tester, find.byKey(const Key('scan-manual-submit')));
    final field = tester.widget<TextField>(
      find.byKey(const Key('scan-manual-field')),
    );
    expect(field.decoration?.errorText, isNotNull, reason: 'bad check digit');
    await tester.enterText(
      find.byKey(const Key('scan-manual-field')),
      unknownGtin,
    );
    await tester.pump();
    await tapVisible(tester, find.byKey(const Key('scan-manual-submit')));
    await waitFor(
      tester,
      find.byKey(const Key('scan-unknown')),
      reason: 'the question about an unknown number',
    );
    await tapVisible(tester, find.byKey(const Key('scan-unknown-search')));
    await enterField(
      tester,
      const Key('catalog-search-text'),
      unknownProductSearch,
    );
    await tapVisible(tester, find.byKey(const Key('catalog-search-go')));
    await waitFor(tester, _resultTile(), reason: 'the search results');
    await tapVisible(tester, _resultTile());
    await waitFor(
      tester,
      find.byKey(const Key('catalog-linked')),
      reason: 'the product to be linked to the unknown number',
    );
    expect(
      find.byKey(const Key('catalog-consent')),
      findsNothing,
      reason: 'no opt-in without server support',
    );
  });
  final unknown = await _medicationWithGtin(db, unknownGtin14);
  expect(unknown.catalogProductId, isNotNull);
  expect(unknown.catalogPackageId, isNull, reason: 'no package has it');
  expect(unknown.name, unknownProductSearch);
  expect(unknown.gtinLinkShared, isFalse);

  final report = await container.read(syncEngineProvider).sync();
  expect(report.ok, isTrue, reason: 'sync of the linked medications');
  expect(await db.select(db.outbox).get(), isEmpty);
  await quiesce(tester, container);
}

/// Opens the new-medication form from Today, runs [fill], saves, and leaves
/// the schedule editor with its default daily dose.
Future<void> _addMedication(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function() fill,
) async {
  container.read(routerProvider).go(AppRoutes.today);
  await tapVisible(tester, find.byKey(const Key('today-add')));
  await tapVisible(tester, find.byKey(const Key('catalog-scan')));
  await fill();
  await tapVisible(tester, find.byKey(const Key('med-save')));
  await waitFor(
    tester,
    find.byKey(const ValueKey('slot-time-08:00')),
    reason: 'the schedule editor',
  );
  await tapVisible(tester, find.byKey(const Key('schedule-save')));
  await pumpUntil(
    tester,
    () => find.byKey(const Key('schedule-save')).evaluate().isEmpty,
    reason: 'the schedule editor to close',
  );
}

/// Types [number] in the scan sheet (already open) and submits it. Without a
/// camera the sheet switches to typing by itself; with one it is asked to.
Future<void> _typeNumber(
  WidgetTester tester,
  String number, {
  bool submit = true,
}) async {
  final field = find.byKey(const Key('scan-manual-field'));
  final toggle = find.byKey(const Key('scan-manual'));
  var polls = 0;
  await pumpUntil(
    tester,
    () async {
      if (field.evaluate().isNotEmpty) {
        return true;
      }
      // One synchronous check-and-tap: the camera failure may remove the
      // button at any frame, but not between these two statements. A tap
      // that did not switch the sheet (a frame lost to the sheet's slide-in)
      // is repeated every few polls.
      final target = toggle.hitTestable();
      if (polls++ % _retryEveryPolls == 0 && target.evaluate().isNotEmpty) {
        await tester.tap(target.first);
      }
      return false;
    },
    reason: 'the scan sheet to offer typing the number',
  );
  await enterField(tester, const Key('scan-manual-field'), number);
  if (submit) {
    await tapVisible(tester, find.byKey(const Key('scan-manual-submit')));
  }
}

/// The search result tiles of the sheet (one for the synthetic product);
/// no `.first` here: it throws while nothing is found yet.
Finder _resultTile() {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> && key.value.startsWith('catalog-result-');
  });
}

Future<MedicationRow> _medicationWithGtin(
  AppDatabase db,
  String gtin14,
) async {
  final rows = [
    for (final row in await db.select(db.medications).get())
      if (row.gtin == gtin14 && row.deletedAt == null) row,
  ];
  expect(rows, hasLength(1), reason: 'one medication carries the number');
  return rows.single;
}
