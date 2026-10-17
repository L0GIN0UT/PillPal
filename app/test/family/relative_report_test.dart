import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/report/report_model.dart';
import 'package:pillpal/src/features/report/report_pdf.dart';
import 'package:pillpal/src/features/report/report_service.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// The report of a relative is made from what the server projected for the
// user: no hidden medication exists locally, an anonymous one is flagged and
// the PDF prints it as "Medication" without strength or dose (the flag is
// what `report_pdf.dart` checks).

void main() {
  test('is built from the relative profile only, redacted rows flagged',
      () async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await harness.seedMedication(container, name: 'Own Med');
    final profile = await seedProfile(harness, name: 'Grace');
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Shared Med',
    );
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Leaky Name',
      privacy: 'anonymous',
      redacted: true,
    );

    final report = await container.read(reportServiceProvider).build(
          lastDays(LocalDate(2026, 10, 16), 7),
          profileId: profile,
        );

    expect(report.patientName, 'Grace');
    final lines = report.medications;
    expect(lines, hasLength(2));
    expect(
      [for (final line in lines) line.medication.redacted],
      unorderedEquals([false, true]),
    );
    // Nothing of the user's own profile.
    expect(
      [for (final line in lines) line.medication.name],
      isNot(contains('Own Med')),
    );
  });

  test('the PDF table hides the name and dose of anonymous ones', () async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final profile = await seedProfile(harness, name: 'Grace');
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Leaky Name',
      strength: '500 mg',
      privacy: 'anonymous',
      redacted: true,
      leakDoses: true,
    );
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Shared Med',
      strength: '10 mg',
    );
    final report = await container.read(reportServiceProvider).build(
          lastDays(LocalDate(2026, 10, 16), 7),
          profileId: profile,
        );

    for (final locale in ['en', 'ru']) {
      final l10n = lookupAppLocalizations(Locale(locale));
      final rows = medicationTableRows(report, l10n, locale);
      final anonymous = rows.singleWhere(
        (row) => row.first == l10n.redactedMedication,
      );
      final text = anonymous.join('\n').toLowerCase();

      expect(text, isNot(contains('leaky')), reason: locale);
      expect(text, isNot(contains('500')), reason: locale);
      expect(text, isNot(contains('tablet')), reason: locale);
      expect(text, isNot(contains('таблет')), reason: locale);
      // The schedule days are disclosed, the doses are not.
      expect(anonymous[1], isNotEmpty, reason: locale);
      // A shared medication keeps its name and strength.
      expect(
        rows.any((row) => row.first == 'Shared Med 10 mg'),
        isTrue,
        reason: locale,
      );
    }
  });

  group('the note under the period', () {
    Future<void> openSheet(
      WidgetTester tester, {
      required String role,
      required String kind,
      String? profileId,
    }) async {
      useTallPhoneSurface(tester);
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      final profile = profileId ??
          await seedProfile(harness, role: role, kind: kind, name: 'Grace');
      await pumpApp(tester, harness: harness, container: container);
      openRoute(
        container,
        profileId == null
            ? AppRoutes.profileHistory(profile)
            : AppRoutes.history,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('history-pdf')));
      await tester.pumpAndSettle();
    }

    testWidgets('a guardian gets the full-access note, not the relative one',
        (tester) async {
      await openSheet(tester, role: 'guardian', kind: 'managed');

      expect(
        find.textContaining('lists all medications of this profile'),
        findsOneWidget,
      );
      expect(find.textContaining('shows only what you may see'), findsNothing);
      expect(find.byKey(const Key('report-include-hidden')), findsOneWidget);
    });

    testWidgets('a viewer gets the note about what is left out',
        (tester) async {
      await openSheet(tester, role: 'viewer', kind: 'self');

      expect(
        find.textContaining('shows only what you may see'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('report-include-hidden')), findsNothing);
    });

    testWidgets('an unknown role is treated as a relative', (tester) async {
      useTallPhoneSurface(tester);
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      final profile = await seedProfile(
        harness,
        role: 'guardian',
        kind: 'managed',
        withScope: false,
      );
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.profileHistory(profile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('history-pdf')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('report-include-hidden')), findsNothing);
      expect(
        find.textContaining('shows only what you may see'),
        findsOneWidget,
      );
    });

    testWidgets('the own profile keeps its own note', (tester) async {
      await openSheet(
        tester,
        role: 'owner',
        kind: 'self',
        profileId: selfProfileId,
      );

      expect(
        find.textContaining('lists all your medications'),
        findsOneWidget,
      );
    });
  });
}
