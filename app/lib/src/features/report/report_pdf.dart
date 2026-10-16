import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/formatters.dart';
import '../doses/dose_status.dart';
import '../schedule/schedule_text.dart';
import 'report_model.dart';

/// Bundled fonts with Cyrillic glyphs (the PDF base fonts have none).
class ReportFonts {
  /// Creates the fonts.
  const ReportFonts({required this.regular, required this.bold});

  /// Body text.
  final pw.Font regular;

  /// Headings and table headers.
  final pw.Font bold;

  /// Nunito from the app's assets.
  static Future<ReportFonts> load(AssetBundle bundle) async => ReportFonts(
        regular: pw.Font.ttf(await bundle.load('assets/fonts/Nunito-400.ttf')),
        bold: pw.Font.ttf(await bundle.load('assets/fonts/Nunito-700.ttf')),
      );
}

const double _margin = 36;
const double _small = 8;
const double _body = 10;
const double _title = 18;
const double _gap = 12;
const PdfColor _muted = PdfColors.grey700;
const PdfColor _headerFill = PdfColors.grey200;

/// The report as PDF bytes (A4, generated on the device; nothing is
/// uploaded). Every page carries the "конфиденциально" header.
Future<Uint8List> renderDoctorReport(
  DoctorReport report, {
  required AppLocalizations l10n,
  required String locale,
  required ReportFonts fonts,
}) {
  final doc = pw.Document(title: l10n.reportTitle, creator: l10n.appTitle);
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(_margin),
      theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
      header: (context) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(bottom: _gap),
        child: pw.Text(
          l10n.reportConfidential,
          style: const pw.TextStyle(fontSize: _small, color: _muted),
        ),
      ),
      footer: (context) => pw.Container(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          l10n.reportPage(context.pageNumber, context.pagesCount),
          style: const pw.TextStyle(fontSize: _small, color: _muted),
        ),
      ),
      build: (context) => [
        ..._intro(report, l10n, locale),
        pw.SizedBox(height: _gap * 2),
        _heading(l10n.reportMedicationsTitle),
        _medicationTable(report, l10n, locale),
        pw.SizedBox(height: _gap * 2),
        _heading(l10n.reportDaysTitle),
        _dayTable(report, l10n, locale),
        pw.SizedBox(height: _gap),
        pw.Text(
          l10n.reportFootnote(DoseTiming.missedGrace.inMinutes),
          style: const pw.TextStyle(fontSize: _small, color: _muted),
        ),
      ],
    ),
  );
  return doc.save();
}

List<pw.Widget> _intro(
  DoctorReport report,
  AppLocalizations l10n,
  String locale,
) {
  final percent = report.total.adherencePercent;
  final name = report.patientName;
  return [
    pw.Text(
      l10n.reportTitle,
      style: pw.TextStyle(fontSize: _title, fontWeight: pw.FontWeight.bold),
    ),
    pw.SizedBox(height: _gap / 2),
    if (name != null && name.isNotEmpty) pw.Text(l10n.reportPatient(name)),
    pw.Text(
      l10n.reportPeriod(
        formatShortDate(report.range.first, locale),
        formatShortDate(report.range.last, locale),
      ),
    ),
    pw.Text(
      percent == null
          ? l10n.reportNothingDue
          : l10n.reportAdherence(
              percent,
              report.total.taken,
              report.total.planned,
            ),
    ),
    pw.Text(
      l10n.reportGenerated(formatShortDate(report.generatedOn, locale)),
      style: const pw.TextStyle(fontSize: _small, color: _muted),
    ),
  ];
}

pw.Widget _heading(String text) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: _gap / 2),
      child: pw.Text(
        text,
        style: pw.TextStyle(fontSize: _body + 3, fontWeight: pw.FontWeight.bold),
      ),
    );

/// A table whose columns from [firstCount] on are right-aligned numbers.
pw.Widget _table(
  List<String> headers,
  List<List<String>> rows, {
  required int firstCount,
}) {
  return pw.TableHelper.fromTextArray(
    headers: headers,
    data: rows,
    headerStyle: pw.TextStyle(fontSize: _small, fontWeight: pw.FontWeight.bold),
    headerDecoration: const pw.BoxDecoration(color: _headerFill),
    cellStyle: const pw.TextStyle(fontSize: _small),
    cellAlignment: pw.Alignment.centerLeft,
    cellAlignments: {
      for (var column = firstCount; column < headers.length; column++)
        column: pw.Alignment.centerRight,
    },
  );
}

List<String> _countCells(DoseCounts counts) {
  final percent = counts.adherencePercent;
  return [
    '${counts.planned}',
    '${counts.taken}',
    '${counts.skipped}',
    '${counts.missed}',
    '${counts.asNeeded}',
    percent == null ? '—' : '$percent%',
  ];
}

List<String> _countHeaders(AppLocalizations l10n) => [
      l10n.reportColPlanned,
      l10n.reportColTaken,
      l10n.reportColSkipped,
      l10n.reportColMissed,
      l10n.reportColAsNeeded,
      l10n.reportColAdherence,
    ];

pw.Widget _medicationTable(
  DoctorReport report,
  AppLocalizations l10n,
  String locale,
) {
  if (report.medications.isEmpty) {
    return pw.Text(l10n.reportNoMedications);
  }
  return _table(
    [l10n.reportColMedication, l10n.reportColSchedule, ..._countHeaders(l10n)],
    [
      for (final line in report.medications)
        [
          _medicationName(line),
          line.rules.map((rule) => _ruleText(l10n, rule, locale)).join('\n'),
          ..._countCells(line.counts),
        ],
    ],
    firstCount: 2,
  );
}

String _medicationName(MedicationReport line) {
  final strength = line.medication.strengthText;
  final name = line.medication.name;
  return strength == null || strength.isEmpty ? name : '$name $strength';
}

/// "Каждый день · 08:00, 20:00 · 1 таблетка".
String _ruleText(AppLocalizations l10n, ScheduleRule rule, String locale) {
  final doses = {
    for (final slot in rule.times)
      formatDose(l10n, slot.dose.amount, slot.dose.unit.name, locale),
  };
  final summary = scheduleSummary(l10n, rule, locale);
  return doses.isEmpty ? summary : '$summary · ${doses.join(' / ')}';
}

pw.Widget _dayTable(
  DoctorReport report,
  AppLocalizations l10n,
  String locale,
) {
  return _table(
    [l10n.reportColDate, ..._countHeaders(l10n)],
    [
      for (final day in report.days)
        [formatShortDate(day.date, locale), ..._countCells(day.counts)],
    ],
    firstCount: 1,
  );
}
