import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../history/history_providers.dart';
import 'report_model.dart';
import 'report_pdf.dart';

/// Hands a finished PDF to the system share sheet.
abstract interface class ReportSharer {
  /// Shares [bytes] as [filename].
  Future<void> share(Uint8List bytes, String filename);
}

/// [ReportSharer] over `printing` (share sheet on Android and iOS).
class PrintingReportSharer implements ReportSharer {
  /// Creates the sharer.
  const PrintingReportSharer();

  @override
  Future<void> share(Uint8List bytes, String filename) async {
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }
}

/// Renders a report to PDF bytes.
typedef ReportRenderer = Future<Uint8List> Function(
  DoctorReport report,
  AppLocalizations l10n,
  String locale,
);

/// The share sheet (tests override it with a fake).
final reportSharerProvider = Provider<ReportSharer>(
  (ref) => const PrintingReportSharer(),
);

/// The PDF renderer with the bundled fonts (tests may override it).
final reportRendererProvider = Provider<ReportRenderer>(
  (ref) => (report, l10n, locale) async => renderDoctorReport(
        report,
        l10n: l10n,
        locale: locale,
        fonts: await ReportFonts.load(rootBundle),
      ),
);

/// Builds and shares doctor's reports.
final reportServiceProvider = Provider<ReportService>(ReportService.new);

/// The doctor's report (TZ §2.4): made from the local database on the
/// device, shared only through the system share sheet.
class ReportService {
  /// Creates the service.
  ReportService(this._ref);

  final Ref<Object?> _ref;

  /// The report of [range] from the stored rows.
  Future<DoctorReport> build(ReportRange range) async {
    final tz = _ref.read(deviceTimeZoneProvider);
    final now = _ref.read(clockProvider)();
    final medications = await _ref.read(selfMedicationsProvider.future);
    final schedules = await _ref.read(parsedSchedulesProvider.future);
    final profile = await _ref.read(selfProfileProvider.future);
    final window = dayWindow(range.first, range.last, tz);
    // The same events as History reads for these days (ADR 0003 §5).
    final events = await _ref
        .read(doseEventsRepositoryProvider)
        .watchForDays(
          scheduleIds: [for (final schedule in schedules) schedule.row.id],
          firstDay: window.first.addDays(-1),
          lastDay: window.last.addDays(1),
          from: window.from,
          to: window.to,
        )
        .first;
    final days = buildHistoryDays(
      medications: medications,
      schedules: schedules,
      events: events,
      window: window,
      deviceTz: tz,
      now: now,
    );
    return buildDoctorReport(
      range: range,
      days: days,
      medications: medications,
      schedules: schedules,
      today: localDateOf(now, tz),
      patientName: profile?.displayName,
    );
  }

  /// Builds, renders and shares the report of [range]. The file name holds
  /// dates only, no medical data.
  Future<void> share(
    ReportRange range,
    AppLocalizations l10n,
    String locale,
  ) async {
    final report = await build(range);
    final bytes = await _ref.read(reportRendererProvider)(report, l10n, locale);
    await _ref
        .read(reportSharerProvider)
        .share(bytes, 'pillpal-report-${range.first}-${range.last}.pdf');
  }
}
