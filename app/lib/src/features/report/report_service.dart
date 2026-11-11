import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../family/profile_context.dart';
import '../history/history_providers.dart';
import 'report_history.dart';
import 'report_model.dart';
import 'report_pdf.dart';

/// Renders a report to PDF bytes.
typedef ReportRenderer = Future<Uint8List> Function(
  DoctorReport report,
  AppLocalizations l10n,
  String locale,
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

/// Builds and keeps doctor's reports.
final reportServiceProvider = Provider<ReportService>(ReportService.new);

/// The doctor's report (TZ §2.4): made from the local database on the
/// device and kept there (docs/adr/0019); it leaves only when the person
/// opens, saves or shares it (`ReportActions`).
class ReportService {
  /// Creates the service.
  ReportService(this._ref);

  final Ref<Object?> _ref;

  /// The report of [range] from the stored rows of [profileId] (null: the
  /// user's own `self` profile).
  ///
  /// The report of a profile the user runs has every medication; with
  /// [includeHidden] false it leaves out the ones marked `hidden` ("Только
  /// мне"). The report of a relative is made from what the server projected
  /// for the user: no `hidden` medication exists locally, and `anonymous`
  /// ones have no name, strength or dose, so the PDF cannot show them.
  Future<DoctorReport> build(
    ReportRange range, {
    String? profileId,
    bool includeHidden = true,
  }) async {
    final access = await _ref.read(profileAccessProvider(profileId).future);
    final deviceTz = _ref.read(deviceTimeZoneProvider);
    // The same days and times as the History of that profile.
    final tz = access?.localZone(deviceTz) ?? deviceTz;
    final now = _ref.read(clockProvider)();
    final medications = [
      for (final medication
          in await _ref.read(profileMedicationsProvider(profileId).future))
        if (includeHidden || medication.privacy != 'hidden') medication,
    ];
    final schedules =
        await _ref.read(profileSchedulesProvider(profileId).future);
    final profile =
        access?.profile ?? await _ref.read(selfProfileProvider.future);
    final window = dayWindow(range.first, range.last, tz);
    // The same events as History reads for these days (ADR 0003 §5).
    final events = await _ref.read(doseEventsRepositoryProvider).watchForDays(
      scheduleIds: [for (final schedule in schedules) schedule.row.id],
      firstDay: window.first.addDays(-1),
      lastDay: window.last.addDays(1),
      from: window.from,
      to: window.to,
    ).first;
    final days = buildHistoryDays(
      medications: medications,
      schedules: schedules,
      events: [
        for (final event in events)
          if (event.profileId == profile?.id) event,
      ],
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

  /// Builds and renders the report of [range] and keeps the PDF on the
  /// device ([ReportHistory]); the file name holds dates only, no medical
  /// data. Returns the kept report; the caller opens, saves or shares it.
  Future<StoredReport> create(
    ReportRange range,
    AppLocalizations l10n,
    String locale, {
    String? profileId,
    bool includeHidden = true,
  }) async {
    final report = await build(
      range,
      profileId: profileId,
      includeHidden: includeHidden,
    );
    final bytes = await _ref.read(reportRendererProvider)(report, l10n, locale);
    final ownerId =
        profileId ?? (await _ref.read(selfProfileProvider.future))?.id;
    if (ownerId == null) {
      throw StateError('No profile to keep a report for');
    }
    return _ref.read(reportHistoryProvider).add(
          profileId: ownerId,
          range: range,
          includeHidden: includeHidden,
          bytes: bytes,
        );
  }
}
