import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/history/history_model.dart';
import 'package:pillpal/src/features/report/report_model.dart';
import 'package:pillpal/src/features/report/report_pdf.dart';
import 'package:pillpal/src/features/report/report_service.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';

/// Records what would be shared.
class _FakeSharer implements ReportSharer {
  final List<String> files = [];

  @override
  Future<void> share(Uint8List bytes, String filename) async {
    files.add(filename);
  }
}

/// "Med R 10 mg" daily at 08:00 and 20:00 from Oct 10; now Oct 16 10:00
/// (UTC+4). Taken: Oct 10-14 both, Oct 15 morning only (evening missed);
/// skipped: Oct 16 08:00; one as-needed "Spray" intake on Oct 12.
Future<void> _seed(TestHarness harness, ProviderContainer container) async {
  await harness.seedSelfProfile();
  final med = await harness.seedMedication(
    container,
    name: 'Med R',
    strength: '10 mg',
    privacy: 'hidden',
  );
  final schedule = await harness.seedSchedule(
    container,
    med,
    testRule(times: ['08:00', '20:00'], startDate: '2026-10-10'),
  );
  final spray = await harness.seedMedication(container, name: 'Spray');
  await harness.seedSchedule(
    container,
    spray,
    testRule(kind: 'as_needed', times: const [], startDate: '2026-10-01'),
  );
  final events = container.read(doseEventsRepositoryProvider);
  Future<void> mark(int day, String time, DoseEventType type) => events.record(
        medicationId: med,
        type: type,
        at: DateTime.utc(2026, 10, day, int.parse(time.substring(0, 2)) - 4, 5),
        occurrence: OccurrenceRef(
          scheduleId: schedule,
          localDate: LocalDate(2026, 10, day),
          localTime: time,
        ),
      );
  for (var day = 10; day <= 14; day++) {
    await mark(day, '08:00', DoseEventType.taken);
    await mark(day, '20:00', DoseEventType.taken);
  }
  await mark(15, '08:00', DoseEventType.taken);
  await mark(16, '08:00', DoseEventType.skipped);
  await events.record(
    medicationId: spray,
    type: DoseEventType.taken,
    at: DateTime.utc(2026, 10, 12, 12),
  );
}

void main() {
  group('report model', () {
    test('preset ranges end today', () {
      final today = LocalDate(2026, 10, 16);
      final week = lastDays(today, 7);
      expect(week.first, LocalDate(2026, 10, 10));
      expect(week.last, today);
      expect(rangeLength(week), 7);
      expect(rangeLength(lastDays(today, 90)), 90);
    });

    test('counts by outcome; planned excludes doses still pending', () {
      const counts = DoseCounts(taken: 3, skipped: 1, missed: 1, asNeeded: 2);
      expect(counts.planned, 5);
      expect(counts.adherencePercent, 60);
      expect(const DoseCounts(asNeeded: 4).adherencePercent, isNull);
    });

    test('built from the stored rows like History', () async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await _seed(harness, container);

      final report = await container
          .read(reportServiceProvider)
          .build(lastDays(LocalDate(2026, 10, 16), 7));

      expect(report.patientName, 'Test User');
      expect(report.generatedOn, LocalDate(2026, 10, 16));
      expect(report.days, hasLength(7));
      // Oct 10-15: 12 due (11 taken, Oct 15 20:00 missed); Oct 16 08:00
      // skipped, 20:00 still pending (not counted).
      expect(report.total.planned, 13);
      expect(report.total.taken, 11);
      expect(report.total.skipped, 1);
      expect(report.total.missed, 1);
      expect(report.total.asNeeded, 1);
      expect(report.total.adherencePercent, 85);

      // Every medication of the user, hidden ones included, by name.
      expect(
        [for (final line in report.medications) line.medication.name],
        ['Med R', 'Spray'],
      );
      final spray = report.medications.last;
      expect(spray.counts.asNeeded, 1);
      expect(spray.counts.planned, 0);
      expect(spray.rules.single.kind, RuleKind.asNeeded);

      final oct15 = report.days[5];
      expect(oct15.date, LocalDate(2026, 10, 15));
      expect(oct15.counts.taken, 1);
      expect(oct15.counts.missed, 1);
      expect(report.days[2].counts.asNeeded, 1);
    });

    test('medications without doses or schedules in the period are left out',
        () {
      MedicationRow medication(String id) => MedicationRow(
            id: id,
            profileId: 'p',
            name: id,
            tzMode: 'local',
            privacy: 'shared',
            clientUpdatedAt: 1,
            updatedByDevice: 'd',
          );
      ParsedSchedule schedule(String medicationId, String end) =>
          ParsedSchedule(
            ScheduleRow(
              id: 's-$medicationId',
              medicationId: medicationId,
              rule: '{}',
              clientUpdatedAt: 1,
              updatedByDevice: 'd',
            ),
            ScheduleRule.fromJson({
              ...testRule(startDate: '2026-09-01'),
              'end_date': end,
            }),
          );
      final range = lastDays(LocalDate(2026, 10, 16), 7);
      final report = buildDoctorReport(
        range: range,
        days: [
          DayHistory(
            date: range.first,
            adherence: DayAdherence.empty,
            doses: const [],
            intakes: const [],
          ),
        ],
        medications: [medication('ended-before'), medication('overlaps')],
        schedules: [
          schedule('ended-before', '2026-10-01'),
          schedule('overlaps', '2026-10-10'),
        ],
        today: range.last,
      );
      expect(
        [for (final line in report.medications) line.medication.id],
        ['overlaps'],
      );
    });
  });

  test('renders a PDF with the bundled Cyrillic font', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Done by the app's localization delegates outside tests.
    await initializeDateFormatting('ru');
    final harness = TestHarness();
    final container = createContainer(harness);
    await _seed(harness, container);
    final report = await container
        .read(reportServiceProvider)
        .build(lastDays(LocalDate(2026, 10, 16), 90));

    final bytes = await renderDoctorReport(
      report,
      l10n: lookupAppLocalizations(const Locale('ru')),
      locale: 'ru',
      fonts: await ReportFonts.load(rootBundle),
    );

    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    // 90 day rows need more than one page.
    expect(bytes.length, greaterThan(10000));
  });

  testWidgets('History shares the report of the chosen period', (tester) async {
    final harness = TestHarness();
    final sharer = _FakeSharer();
    final rendered = <DoctorReport>[];
    final container = createContainer(
      harness,
      overrides: [
        reportSharerProvider.overrideWithValue(sharer),
        reportRendererProvider.overrideWithValue((report, l10n, locale) async {
          rendered.add(report);
          return Uint8List.fromList(const [1, 2, 3]);
        }),
      ],
    );
    await _seed(harness, container);
    await pumpApp(tester, harness: harness, container: container);

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history-pdf')));
    await tester.pumpAndSettle();
    expect(find.text('Period: Sep 17, 2026 – Oct 16, 2026'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('report-days-7')));
    await tester.pump();
    expect(find.text('Period: Oct 10, 2026 – Oct 16, 2026'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report-share')));
    // The button spins while the report is made: step until it is shared.
    for (var i = 0; i < 50 && sharer.files.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(sharer.files, ['pillpal-report-2026-10-10-2026-10-16.pdf']);
    expect(rendered.single.total.planned, 13);
    expect(find.byKey(const Key('report-share')), findsNothing);
  });
}
