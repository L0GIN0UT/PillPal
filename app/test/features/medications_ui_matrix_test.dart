import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/catalog/catalog_providers.dart';
import 'package:pillpal/src/features/catalog/scan_flow.dart';
import 'package:pillpal/src/features/common/beside_or_below.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/history/history_providers.dart';
import 'package:pillpal/src/features/medications/medication_form.dart';
import 'package:pillpal/src/features/medications/medication_form_view.dart';
import 'package:pillpal/src/features/medications/medication_providers.dart';
import 'package:pillpal/src/features/medications/medications_screen.dart';
import 'package:pillpal/src/features/stock/stock_level.dart';
import 'package:pillpal/src/features/stock/stock_providers.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../support/ui_matrix.dart';

// Medications and the medication form in the whole UI matrix
// (docs/ui-pass-plan.md, UI-7). Data is synthetic; providers are fixed here,
// so no database is involved. The schedule editor has its own file.

/// The profile switcher reads the access scopes from the database: the tab
/// screen (no `profileId`) watches it, so the scopes are fixed too. Without
/// this the real database opens and fails once a test lets time pass.
final Override _noScopes = accessScopesProvider.overrideWith(
  (ref) => Stream.value(const <AccessScopeRow>[]),
);

const String _zone = 'Europe/Moscow';

ProfileRow _profile(String id, String kind, String name) => ProfileRow(
      id: id,
      kind: kind,
      displayName: name,
      timezone: _zone,
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
      missedAlertMinutes: 30,
      missedAlertsEnabled: true,
    );

final ProfileAccess _own = ProfileAccess(
  profile: _profile('self-1', 'self', 'Test User'),
  role: 'owner',
);
final ProfileAccess _ward = ProfileAccess(
  profile: _profile('ward-1', 'managed', 'Pat Ward'),
  role: 'owner',
);

MedicationRow _medication(String id, String name, {String? strength}) =>
    MedicationRow(
      id: id,
      profileId: 'self-1',
      name: name,
      strengthText: strength,
      tzMode: 'local',
      privacy: 'shared',
      redacted: false,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
    );

final List<MedicationRow> _medications = [
  _medication('med-1', 'Synthetic Tablet', strength: '500 mg'),
  _medication(
    'med-2',
    'Очень длинное название синтетического лекарства для проверки переноса',
    strength: '20 мг',
  ),
];

/// A medication of someone else's that the owner made `anonymous`: the row
/// is redacted, so it has no name, strength or stock for the viewer.
MedicationRow _redacted() => const MedicationRow(
      id: 'med-3',
      profileId: 'self-1',
      name: null,
      strengthText: '5 mg',
      tzMode: 'local',
      privacy: 'anonymous',
      redacted: true,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
    );

Widget _fill(Widget child) => SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: child,
    );

// med-1 runs out in 3 days (a low-stock pill); med-2 has plenty.
const StockKnown _lowStock =
    StockKnown(remainingMilli: 5000, unit: DoseUnit.tablet, daysLeft: 3);
const StockKnown _plentyStock =
    StockKnown(remainingMilli: 60000, unit: DoseUnit.tablet, daysLeft: 30);

Widget _scope(
  Widget child, {
  bool catalog = true,
  List<MedicationRow>? medications,
}) {
  final rows = medications ?? _medications;
  return ProviderScope(
    overrides: [
      _noScopes,
      deviceTimeZoneProvider.overrideWithValue(_zone),
      nowProvider.overrideWithValue(DateTime.utc(2026, 10, 16, 9)),
      catalogEnabledProvider.overrideWithValue(catalog),
      historyZoneProvider(null).overrideWithValue(_zone),
      profileAccessProvider(null).overrideWith((ref) => Stream.value(_own)),
      accessibleProfilesProvider.overrideWith(
        (ref) => Stream.value([_own, _ward]),
      ),
      profileMedicationsProvider(null).overrideWith(
        (ref) => Stream.value(rows),
      ),
      stockLevelProvider('med-1').overrideWithValue(_lowStock),
      stockLevelProvider('med-2').overrideWithValue(_plentyStock),
      // Even a stock the provider knows is never shown on a redacted row.
      stockLevelProvider('med-3').overrideWithValue(_lowStock),
      medicationSchedulesProvider('med-3').overrideWith(
        (ref) => Stream.value(const <ParsedSchedule>[]),
      ),
      profileSchedulesProvider(null).overrideWith(
        (ref) => Stream.value(const <ParsedSchedule>[]),
      ),
      for (final medication in _medications)
        medicationSchedulesProvider(medication.id).overrideWith(
          (ref) => Stream.value(const <ParsedSchedule>[]),
        ),
    ],
    child: _fill(child),
  );
}

/// Removes the screen and lets autoDispose providers finish their timers.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

/// Lets the streams deliver, then makes the screen tall (a list builds only
/// what is near the viewport) and checks the touch targets.
Future<void> _settle(WidgetTester tester, UiMatrixCase cell) async {
  await tester.pump();
  await tester.pump();
  tester.view.physicalSize = Size(cell.size.width, 20000);
  await tester.pump();
  expectTouchTargetsOf(tester, cell);
}

void main() {
  testWidgets('Medications list', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(const MedicationsScreen()),
      expectTouchTargets: true,
      expectContrast: true,
      check: (tester, cell) async {
        await _settle(tester, cell);
        expect(find.byKey(const Key('medication-med-1')), findsOneWidget);
        expect(find.byKey(const Key('medication-med-2')), findsOneWidget);
        expect(find.byKey(const Key('medications-scan')), findsOneWidget);
        expect(find.byKey(const Key('medications-add')), findsOneWidget);
        // Two profiles: the profile button of the header (B-Medications).
        expect(find.byKey(const Key('medications-profile')), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const Key('medications-scan'))).height,
          greaterThanOrEqualTo(cell.touchTarget),
        );
      },
    );
    await _dispose(tester);
  });

  testWidgets('a running-low medication has a soft pill, never danger',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(const MedicationsScreen()),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await _settle(tester, cell);
        final pill = find.byKey(const Key('stock-pill-med-1'));
        expect(pill, findsOneWidget);
        expect(find.byKey(const Key('stock-pill-med-2')), findsNothing);
        expect(tester.widget<StatusPill>(pill).kind, StatusKind.lowStock);
        // The word and the icon say it, and no red is involved.
        final palette =
            Theme.of(tester.element(pill)).extension<PillPalPalette>();
        expect(palette, isNotNull);
        final dangers = find.byWidgetPredicate(
          (w) => w is Icon && w.color == palette!.danger,
        );
        expect(dangers, findsNothing);
      },
    );
    await _dispose(tester);
  });

  testWidgets('a redacted row shows no stock, in any form', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(
        const MedicationsScreen(),
        medications: [_medications.first, _redacted()],
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await _settle(tester, cell);
        final redacted = find.byKey(const Key('medication-med-3'));
        expect(redacted, findsOneWidget);
        // The normal row has its pill; the redacted one has neither pill nor
        // «Left» line nor the strength.
        expect(find.byKey(const Key('stock-pill-med-1')), findsOneWidget);
        expect(find.byKey(const Key('stock-pill-med-3')), findsNothing);
        expect(
          find.descendant(of: redacted, matching: find.textContaining('5 mg')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: redacted,
            matching: find.textContaining(RegExp('Left|Осталось')),
          ),
          findsNothing,
        );
      },
    );
    await _dispose(tester);
  });

  testWidgets('no «+» and no scan button while the list loads', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => ProviderScope(
        overrides: [
          _noScopes,
          deviceTimeZoneProvider.overrideWithValue(_zone),
          catalogEnabledProvider.overrideWithValue(true),
          profileAccessProvider(null).overrideWith((ref) => Stream.value(_own)),
          accessibleProfilesProvider
              .overrideWith((ref) => Stream.value([_own, _ward])),
          profileMedicationsProvider(null).overrideWith(
            (ref) => const Stream<List<MedicationRow>>.empty(),
          ),
        ],
        child: _fill(const MedicationsScreen()),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await tester.pump();
        expect(find.byKey(const Key('medications-add')), findsNothing);
        expect(find.byKey(const Key('medications-scan')), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );
    await _dispose(tester);
  });

  testWidgets(
      'the header actions go under the title from x1.6, or when the title '
      'fits only alone (section 9.3)', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(const MedicationsScreen()),
      scales: const [1.0, 2.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await _settle(tester, cell);
        final title = find.byKey(const Key('medications-title'));
        final add = find.byKey(const Key('medications-add'));
        final beside =
            tester.getTopLeft(add).dy < tester.getBottomLeft(title).dy;
        final compact = cell.scale * (cell.senior ? 1.3 : 1) >= 1.6;
        if (compact) {
          expect(beside, isFalse, reason: cell.label);
          return;
        }
        if (!beside) {
          // Below x1.6 the actions leave the line only for a title that is
          // one line alone but not beside them (the test font is wide).
          final header = find.byType(BesideOrBelow);
          final actions =
              find.ancestor(of: add, matching: find.byType(Row)).first;
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: title, matching: find.byType(RichText)),
          );
          final line = paragraph.getMaxIntrinsicWidth(double.infinity);
          final width = tester.getSize(header).width;
          expect(line, lessThanOrEqualTo(width), reason: cell.label);
          expect(
            line + tester.getSize(actions).width,
            greaterThan(width),
            reason: cell.label,
          );
        }
      },
    );
    await _dispose(tester);
  });

  testWidgets('empty list: the board offers scan and manual entry',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(const MedicationsScreen(), medications: const []),
      expectTouchTargets: true,
      expectContrast: true,
      check: (tester, cell) async {
        await tester.pump();
        await tester.pump();
        expectTouchTargetsOf(tester, cell);
        expect(find.byKey(const Key('empty-state-disc')), findsOneWidget);
        // The scan entry is the primary action, not a floating button; "+" is
        // the secondary action, so the key appears once.
        expect(find.byKey(const Key('medications-scan')), findsOneWidget);
        expect(find.byKey(const Key('medications-add')), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsNothing);
      },
    );
    await _dispose(tester);
  });

  testWidgets('empty list without a catalog offers manual entry only',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(
        const MedicationsScreen(),
        catalog: false,
        medications: const [],
      ),
      scales: const [2.0],
      expectTouchTargets: true,
      check: (tester, cell) async {
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('medications-scan')), findsNothing);
        expect(find.byKey(const Key('medications-add')), findsOneWidget);
      },
    );
    await _dispose(tester);
  });

  testWidgets('Medications list without a catalog has no scan button',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(const MedicationsScreen(), catalog: false),
      expectTouchTargets: true,
      scales: const [2.0],
      check: (tester, cell) async {
        await _settle(tester, cell);
        expect(find.byKey(const Key('medication-med-1')), findsOneWidget);
        expect(find.byKey(const Key('medications-scan')), findsNothing);
      },
    );
    await _dispose(tester);
  });

  testWidgets('Medication form: catalog, stock and fixed zone', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(
        const MedicationFormView(
          medicationId: null,
          initial: MedicationFormInput(
            name: 'Synthetic Tablet',
            fixedZone: true,
            zone: _zone,
            trackStock: true,
            stockCount: '10',
            stockUnit: 'tablet',
          ),
        ),
      ),
      expectTouchTargets: true,
      check: (tester, cell) async {
        await _settle(tester, cell);
        expect(find.byKey(const Key('catalog-scan')), findsOneWidget);
        expect(find.byKey(const Key('med-name')), findsOneWidget);
        expect(find.byKey(const Key('med-save')), findsOneWidget);
        // B2-AddMedication: two tiles on top, side by side until the text is
        // large (a pair of buttons is stacked from x1.6, section 9.6).
        final scan = find.byKey(const Key('catalog-scan'));
        final manual = find.byKey(const Key('catalog-manual'));
        expect(manual, findsOneWidget);
        final sameRow =
            tester.getTopLeft(scan).dy == tester.getTopLeft(manual).dy;
        expect(sameRow, cell.scale * (cell.senior ? 1.3 : 1) < 1.3,
            reason: cell.label);
        expect(tester.getSize(scan).height,
            greaterThanOrEqualTo(cell.touchTarget));
      },
    );
    await _dispose(tester);
  });

  testWidgets('the manual tile puts the cursor in the name field',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(
        const MedicationFormView(
          medicationId: null,
          initial: MedicationFormInput(),
        ),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await _settle(tester, cell);
        await tester.tap(find.byKey(const Key('catalog-manual')));
        await tester.pump();
        final name = find.descendant(
          of: find.byKey(const Key('med-name')),
          matching: find.byType(EditableText),
        );
        expect(tester.widget<EditableText>(name).focusNode.hasFocus, isTrue);
      },
    );
    await _dispose(tester);
  });

  testWidgets('an existing medication never opens the scanner', (tester) async {
    var scanners = 0;
    await pumpUiMatrix(
      tester,
      (context) => ProviderScope(
        overrides: [
          deviceTimeZoneProvider.overrideWithValue(_zone),
          catalogEnabledProvider.overrideWithValue(true),
          profileAccessProvider(null).overrideWith(
            (ref) => Stream.value(_own),
          ),
          scannerAdapterFactoryProvider.overrideWithValue(() {
            scanners++;
            throw StateError('the scanner must not open');
          }),
        ],
        child: _fill(
          MedicationFormView(
            medicationId: 'x',
            autoScan: true,
            initial: const MedicationFormInput(name: 'Synthetic Tablet'),
            row: _medications.first,
          ),
        ),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('scan-manual')), findsNothing);
        // Manual entry is the way to add a medication, not to edit one.
        expect(find.byKey(const Key('catalog-manual')), findsNothing);
      },
    );
    expect(scanners, 0);
    await _dispose(tester);
  });
}
