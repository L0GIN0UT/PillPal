import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import '../history/history_model.dart';

// The doctor's report (TZ §2.4 "PDF-отчёт для врача за период"): pure data
// built from the same day histories as the History screen, so the report
// and the calendar always agree. Rendering is in report_pdf.dart.

/// Preset report lengths in days ("7 / 30 / 90 дней").
const List<int> reportPresetDays = [7, 30, 90];

/// Longest custom period, in days.
const int maxReportDays = 366;

/// An inclusive range of device-local dates.
typedef ReportRange = ({LocalDate first, LocalDate last});

/// The last [days] days up to and including [today].
ReportRange lastDays(LocalDate today, int days) =>
    (first: today.addDays(1 - days), last: today);

/// Number of days in [range].
int rangeLength(ReportRange range) {
  var count = 0;
  for (var day = range.first; !day.isAfter(range.last); day = day.addDays(1)) {
    count++;
  }
  return count;
}

/// Due doses by outcome. Doses still pending (time not reached, or within
/// the grace period) are not counted: they have no outcome yet.
class DoseCounts {
  /// Creates counts.
  const DoseCounts({
    this.taken = 0,
    this.skipped = 0,
    this.missed = 0,
    this.asNeeded = 0,
  });

  /// Taken doses.
  final int taken;

  /// Deliberately skipped doses.
  final int skipped;

  /// Missed doses.
  final int missed;

  /// As-needed intakes (not part of the plan).
  final int asNeeded;

  /// Planned doses that were due: taken + skipped + missed.
  int get planned => taken + skipped + missed;

  /// Taken share of the planned doses in percent; null when none was due.
  int? get adherencePercent =>
      planned == 0 ? null : (taken * 100 / planned).round();

  /// These counts with one more dose of [status] / [asNeeded] intakes.
  DoseCounts add({DoseStatus? status, int asNeeded = 0}) => DoseCounts(
        taken: taken + (status == DoseStatus.taken ? 1 : 0),
        skipped: skipped + (status == DoseStatus.skipped ? 1 : 0),
        missed: missed + (status == DoseStatus.missed ? 1 : 0),
        asNeeded: this.asNeeded + asNeeded,
      );
}

/// One medication's line of the report.
class MedicationReport {
  /// Creates a line.
  const MedicationReport({
    required this.medication,
    required this.rules,
    required this.counts,
  });

  /// The medication (name and strength are printed; the report is the
  /// user's own, so every medication is included whatever its privacy).
  final MedicationRow medication;

  /// Its schedules that overlap the period.
  final List<ScheduleRule> rules;

  /// Its doses in the period.
  final DoseCounts counts;
}

/// One day's line of the report.
class DayReport {
  /// Creates a line.
  const DayReport({required this.date, required this.counts});

  /// Device-local date.
  final LocalDate date;

  /// Doses of the day (all medications).
  final DoseCounts counts;
}

/// Everything the PDF shows.
class DoctorReport {
  /// Creates a report.
  const DoctorReport({
    required this.range,
    required this.generatedOn,
    required this.medications,
    required this.days,
    required this.total,
    this.patientName,
  });

  /// The period.
  final ReportRange range;

  /// Date the report was made.
  final LocalDate generatedOn;

  /// The user's display name, if known.
  final String? patientName;

  /// One line per medication with doses or schedules in the period, by name.
  final List<MedicationReport> medications;

  /// One line per day of the period, in order.
  final List<DayReport> days;

  /// All doses of the period.
  final DoseCounts total;
}

/// Builds the report of [range] from its [days] (see `buildHistoryDays`)
/// and the medications and schedules they came from (pure).
DoctorReport buildDoctorReport({
  required ReportRange range,
  required List<DayHistory> days,
  required List<MedicationRow> medications,
  required List<ParsedSchedule> schedules,
  required LocalDate today,
  String? patientName,
}) {
  final perMedication = <String, DoseCounts>{};
  final dayLines = <DayReport>[];
  var total = const DoseCounts();
  for (final day in days) {
    var counts = const DoseCounts();
    for (final dose in day.doses) {
      if (dose.status == DoseStatus.pending) {
        continue;
      }
      final id = dose.medication.id;
      perMedication[id] =
          (perMedication[id] ?? const DoseCounts()).add(status: dose.status);
      counts = counts.add(status: dose.status);
    }
    for (final intake in day.intakes) {
      final id = intake.medicationId;
      perMedication[id] =
          (perMedication[id] ?? const DoseCounts()).add(asNeeded: 1);
      counts = counts.add(asNeeded: 1);
    }
    dayLines.add(DayReport(date: day.date, counts: counts));
    total = DoseCounts(
      taken: total.taken + counts.taken,
      skipped: total.skipped + counts.skipped,
      missed: total.missed + counts.missed,
      asNeeded: total.asNeeded + counts.asNeeded,
    );
  }
  final lines = <MedicationReport>[];
  for (final medication in medications) {
    final rules = [
      for (final schedule in schedules)
        if (schedule.row.medicationId == medication.id &&
            _overlaps(schedule.rule, range))
          schedule.rule,
    ];
    final counts = perMedication[medication.id];
    if (counts == null && rules.isEmpty) {
      continue;
    }
    lines.add(
      MedicationReport(
        medication: medication,
        rules: rules,
        counts: counts ?? const DoseCounts(),
      ),
    );
  }
  lines.sort(
    (a, b) => a.medication.name
        .toLowerCase()
        .compareTo(b.medication.name.toLowerCase()),
  );
  return DoctorReport(
    range: range,
    generatedOn: today,
    patientName: patientName,
    medications: lines,
    days: dayLines,
    total: total,
  );
}

bool _overlaps(ScheduleRule rule, ReportRange range) {
  final end = rule.endDate;
  return !rule.startDate.isAfter(range.last) &&
      (end == null || !end.isBefore(range.first));
}
