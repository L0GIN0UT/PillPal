import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/catalog/catalog_providers.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/history/history_providers.dart';
import 'package:pillpal/src/features/medications/medication_form.dart';
import 'package:pillpal/src/features/medications/medication_form_view.dart';
import 'package:pillpal/src/features/medications/medication_providers.dart';
import 'package:pillpal/src/features/medications/medications_screen.dart';
import 'package:pillpal/src/features/schedule/schedule_draft.dart';
import 'package:pillpal/src/features/schedule/schedule_editor_view.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../support/ui_matrix.dart';

// Medications, the medication form and the schedule editor in the whole UI
// matrix (docs/ui-pass-plan.md, UI-7). Data is synthetic; providers are fixed
// here, so no database is involved.

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

Widget _fill(Widget child) => SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: child,
    );

Widget _scope(Widget child, {bool catalog = true}) {
  return ProviderScope(
    overrides: [
      deviceTimeZoneProvider.overrideWithValue(_zone),
      nowProvider.overrideWithValue(DateTime.utc(2026, 10, 16, 9)),
      catalogEnabledProvider.overrideWithValue(catalog),
      historyZoneProvider(null).overrideWithValue(_zone),
      profileAccessProvider(null).overrideWith((ref) => Stream.value(_own)),
      accessibleProfilesProvider.overrideWith(
        (ref) => Stream.value([_own, _ward]),
      ),
      profileMedicationsProvider(null).overrideWith(
        (ref) => Stream.value(_medications),
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
      check: (tester, cell) async {
        await _settle(tester, cell);
        expect(find.byKey(const Key('medication-med-1')), findsOneWidget);
        expect(find.byKey(const Key('medication-med-2')), findsOneWidget);
        expect(find.byKey(const Key('medications-scan')), findsOneWidget);
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
      },
    );
    await _dispose(tester);
  });

  group('Schedule editor', () {
    final today = LocalDate(2026, 10, 16);
    final base = ScheduleDraft.initial(today);

    final variants = <String, (ScheduleDraft, bool)>{
      'daily, two times, started in the past': (
        base
            .copyWith(startDate: LocalDate(2026, 10, 1), endDate: today)
            .addSlot(),
        false,
      ),
      'weekdays': (base.copyWith(kind: RuleKind.weekdays), false),
      'interval, split note': (
        base.copyWith(kind: RuleKind.intervalDays, intervalDays: 3),
        true,
      ),
      'as needed': (base.copyWith(kind: RuleKind.asNeeded), false),
    };

    for (final entry in variants.entries) {
      testWidgets(entry.key, (tester) async {
        final (draft, started) = entry.value;
        await pumpUiMatrix(
          tester,
          (context) => _scope(
            ScheduleEditorView(
              medication: _medications[1],
              scheduleId: 'sched-1',
              initial: draft,
              today: today,
              ended: false,
              started: started,
              canDelete: true,
            ),
          ),
          expectTouchTargets: true,
          check: (tester, cell) async {
            await _settle(tester, cell);
            expect(find.byKey(const Key('schedule-save')), findsOneWidget);
            expect(find.byKey(const Key('course-start')), findsOneWidget);
          },
        );
        await _dispose(tester);
      });
    }
  });
}
